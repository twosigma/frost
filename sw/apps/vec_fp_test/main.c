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

/* Floating-point arithmetic through retirement, including active-only flags.
 * Register images are initialized and observed through scalar moves.
 */
#include "../vec_common/vec_test.h"
#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif
struct test_case {
    const char *name;
    unsigned vt, vd, regs, rm, flags;
    uint64_t scalar;
    const uint64_t *expected;
};
static unsigned long setvl(unsigned long avl, unsigned long vt)
{
    unsigned long vl;
    __asm__ volatile(".insn r 0x57, 7, 0x40, %0, %1, %2" : "=r"(vl) : "r"(avl), "r"(vt) : "memory");
    return vl;
}
static void splat(unsigned r, uint64_t value)
{
    register uint64_t a0 __asm__("a0") = value;
    switch (r) {
        case 0:
            __asm__ volatile(".word 0x5e054057" ::"r"(a0) : "memory");
            break;
        case 1:
            __asm__ volatile(".word 0x5e0540d7" ::"r"(a0) : "memory");
            break;
        case 2:
            __asm__ volatile(".word 0x5e054157" ::"r"(a0) : "memory");
            break;
        case 3:
            __asm__ volatile(".word 0x5e0541d7" ::"r"(a0) : "memory");
            break;
        case 4:
            __asm__ volatile(".word 0x5e054257" ::"r"(a0) : "memory");
            break;
        case 5:
            __asm__ volatile(".word 0x5e0542d7" ::"r"(a0) : "memory");
            break;
        case 6:
            __asm__ volatile(".word 0x5e054357" ::"r"(a0) : "memory");
            break;
        case 7:
            __asm__ volatile(".word 0x5e0543d7" ::"r"(a0) : "memory");
            break;
        case 8:
            __asm__ volatile(".word 0x5e054457" ::"r"(a0) : "memory");
            break;
        case 9:
            __asm__ volatile(".word 0x5e0544d7" ::"r"(a0) : "memory");
            break;
        case 10:
            __asm__ volatile(".word 0x5e054557" ::"r"(a0) : "memory");
            break;
        case 11:
            __asm__ volatile(".word 0x5e0545d7" ::"r"(a0) : "memory");
            break;
        case 12:
            __asm__ volatile(".word 0x5e054657" ::"r"(a0) : "memory");
            break;
        case 13:
            __asm__ volatile(".word 0x5e0546d7" ::"r"(a0) : "memory");
            break;
        case 14:
            __asm__ volatile(".word 0x5e054757" ::"r"(a0) : "memory");
            break;
        case 15:
            __asm__ volatile(".word 0x5e0547d7" ::"r"(a0) : "memory");
            break;
        case 16:
            __asm__ volatile(".word 0x5e054857" ::"r"(a0) : "memory");
            break;
        case 17:
            __asm__ volatile(".word 0x5e0548d7" ::"r"(a0) : "memory");
            break;
        case 18:
            __asm__ volatile(".word 0x5e054957" ::"r"(a0) : "memory");
            break;
        case 19:
            __asm__ volatile(".word 0x5e0549d7" ::"r"(a0) : "memory");
            break;
        case 20:
            __asm__ volatile(".word 0x5e054a57" ::"r"(a0) : "memory");
            break;
        case 21:
            __asm__ volatile(".word 0x5e054ad7" ::"r"(a0) : "memory");
            break;
        case 22:
            __asm__ volatile(".word 0x5e054b57" ::"r"(a0) : "memory");
            break;
        case 23:
            __asm__ volatile(".word 0x5e054bd7" ::"r"(a0) : "memory");
            break;
        case 24:
            __asm__ volatile(".word 0x5e054c57" ::"r"(a0) : "memory");
            break;
        case 25:
            __asm__ volatile(".word 0x5e054cd7" ::"r"(a0) : "memory");
            break;
        case 26:
            __asm__ volatile(".word 0x5e054d57" ::"r"(a0) : "memory");
            break;
        case 27:
            __asm__ volatile(".word 0x5e054dd7" ::"r"(a0) : "memory");
            break;
        case 28:
            __asm__ volatile(".word 0x5e054e57" ::"r"(a0) : "memory");
            break;
        case 29:
            __asm__ volatile(".word 0x5e054ed7" ::"r"(a0) : "memory");
            break;
        case 30:
            __asm__ volatile(".word 0x5e054f57" ::"r"(a0) : "memory");
            break;
        case 31:
            __asm__ volatile(".word 0x5e054fd7" ::"r"(a0) : "memory");
            break;
    }
}
static uint64_t extract(unsigned r)
{
    register uint64_t a0 __asm__("a0");
    switch (r) {
        case 0:
            __asm__ volatile(".word 0x42002557\n.word 0x3e00b057" : "=r"(a0)::"memory");
            break;
        case 1:
            __asm__ volatile(".word 0x42102557\n.word 0x3e10b0d7" : "=r"(a0)::"memory");
            break;
        case 2:
            __asm__ volatile(".word 0x42202557\n.word 0x3e20b157" : "=r"(a0)::"memory");
            break;
        case 3:
            __asm__ volatile(".word 0x42302557\n.word 0x3e30b1d7" : "=r"(a0)::"memory");
            break;
        case 4:
            __asm__ volatile(".word 0x42402557\n.word 0x3e40b257" : "=r"(a0)::"memory");
            break;
        case 5:
            __asm__ volatile(".word 0x42502557\n.word 0x3e50b2d7" : "=r"(a0)::"memory");
            break;
        case 6:
            __asm__ volatile(".word 0x42602557\n.word 0x3e60b357" : "=r"(a0)::"memory");
            break;
        case 7:
            __asm__ volatile(".word 0x42702557\n.word 0x3e70b3d7" : "=r"(a0)::"memory");
            break;
        case 8:
            __asm__ volatile(".word 0x42802557\n.word 0x3e80b457" : "=r"(a0)::"memory");
            break;
        case 9:
            __asm__ volatile(".word 0x42902557\n.word 0x3e90b4d7" : "=r"(a0)::"memory");
            break;
        case 10:
            __asm__ volatile(".word 0x42a02557\n.word 0x3ea0b557" : "=r"(a0)::"memory");
            break;
        case 11:
            __asm__ volatile(".word 0x42b02557\n.word 0x3eb0b5d7" : "=r"(a0)::"memory");
            break;
        case 12:
            __asm__ volatile(".word 0x42c02557\n.word 0x3ec0b657" : "=r"(a0)::"memory");
            break;
        case 13:
            __asm__ volatile(".word 0x42d02557\n.word 0x3ed0b6d7" : "=r"(a0)::"memory");
            break;
        case 14:
            __asm__ volatile(".word 0x42e02557\n.word 0x3ee0b757" : "=r"(a0)::"memory");
            break;
        case 15:
            __asm__ volatile(".word 0x42f02557\n.word 0x3ef0b7d7" : "=r"(a0)::"memory");
            break;
        case 16:
            __asm__ volatile(".word 0x43002557\n.word 0x3f00b857" : "=r"(a0)::"memory");
            break;
        case 17:
            __asm__ volatile(".word 0x43102557\n.word 0x3f10b8d7" : "=r"(a0)::"memory");
            break;
        case 18:
            __asm__ volatile(".word 0x43202557\n.word 0x3f20b957" : "=r"(a0)::"memory");
            break;
        case 19:
            __asm__ volatile(".word 0x43302557\n.word 0x3f30b9d7" : "=r"(a0)::"memory");
            break;
        case 20:
            __asm__ volatile(".word 0x43402557\n.word 0x3f40ba57" : "=r"(a0)::"memory");
            break;
        case 21:
            __asm__ volatile(".word 0x43502557\n.word 0x3f50bad7" : "=r"(a0)::"memory");
            break;
        case 22:
            __asm__ volatile(".word 0x43602557\n.word 0x3f60bb57" : "=r"(a0)::"memory");
            break;
        case 23:
            __asm__ volatile(".word 0x43702557\n.word 0x3f70bbd7" : "=r"(a0)::"memory");
            break;
        case 24:
            __asm__ volatile(".word 0x43802557\n.word 0x3f80bc57" : "=r"(a0)::"memory");
            break;
        case 25:
            __asm__ volatile(".word 0x43902557\n.word 0x3f90bcd7" : "=r"(a0)::"memory");
            break;
        case 26:
            __asm__ volatile(".word 0x43a02557\n.word 0x3fa0bd57" : "=r"(a0)::"memory");
            break;
        case 27:
            __asm__ volatile(".word 0x43b02557\n.word 0x3fb0bdd7" : "=r"(a0)::"memory");
            break;
        case 28:
            __asm__ volatile(".word 0x43c02557\n.word 0x3fc0be57" : "=r"(a0)::"memory");
            break;
        case 29:
            __asm__ volatile(".word 0x43d02557\n.word 0x3fd0bed7" : "=r"(a0)::"memory");
            break;
        case 30:
            __asm__ volatile(".word 0x43e02557\n.word 0x3fe0bf57" : "=r"(a0)::"memory");
            break;
        case 31:
            __asm__ volatile(".word 0x43f02557\n.word 0x3ff0bfd7" : "=r"(a0)::"memory");
            break;
        default:
            a0 = 0;
            break;
    }
    return a0;
}
static void operation(unsigned k, uint64_t scalar)
{
    __asm__ volatile("fmv.d.x f10, %0" ::"r"(scalar) : "f10");
    switch (k) {
        case 0:
            __asm__ volatile(".word 0x008c1857" ::: "memory");
            break;
        case 1:
            __asm__ volatile(".word 0x02855857" ::: "memory");
            break;
        case 2:
            __asm__ volatile(".word 0x088c1857" ::: "memory");
            break;
        case 3:
            __asm__ volatile(".word 0x0a855857" ::: "memory");
            break;
        case 4:
            __asm__ volatile(".word 0x108c1857" ::: "memory");
            break;
        case 5:
            __asm__ volatile(".word 0x12855857" ::: "memory");
            break;
        case 6:
            __asm__ volatile(".word 0x188c1857" ::: "memory");
            break;
        case 7:
            __asm__ volatile(".word 0x1a855857" ::: "memory");
            break;
        case 8:
            __asm__ volatile(".word 0x208c1857" ::: "memory");
            break;
        case 9:
            __asm__ volatile(".word 0x22855857" ::: "memory");
            break;
        case 10:
            __asm__ volatile(".word 0x248c1857" ::: "memory");
            break;
        case 11:
            __asm__ volatile(".word 0x26855857" ::: "memory");
            break;
        case 12:
            __asm__ volatile(".word 0x288c1857" ::: "memory");
            break;
        case 13:
            __asm__ volatile(".word 0x2a855857" ::: "memory");
            break;
        case 14:
            __asm__ volatile(".word 0x608c1857" ::: "memory");
            break;
        case 15:
            __asm__ volatile(".word 0x62855857" ::: "memory");
            break;
        case 16:
            __asm__ volatile(".word 0x648c1857" ::: "memory");
            break;
        case 17:
            __asm__ volatile(".word 0x66855857" ::: "memory");
            break;
        case 18:
            __asm__ volatile(".word 0x6c8c1857" ::: "memory");
            break;
        case 19:
            __asm__ volatile(".word 0x6e855857" ::: "memory");
            break;
        case 20:
            __asm__ volatile(".word 0x708c1857" ::: "memory");
            break;
        case 21:
            __asm__ volatile(".word 0x72855857" ::: "memory");
            break;
        case 22:
            __asm__ volatile(".word 0x808c1857" ::: "memory");
            break;
        case 23:
            __asm__ volatile(".word 0x82855857" ::: "memory");
            break;
        case 24:
            __asm__ volatile(".word 0x908c1857" ::: "memory");
            break;
        case 25:
            __asm__ volatile(".word 0x92855857" ::: "memory");
            break;
        case 26:
            __asm__ volatile(".word 0xa08c1857" ::: "memory");
            break;
        case 27:
            __asm__ volatile(".word 0xa2855857" ::: "memory");
            break;
        case 28:
            __asm__ volatile(".word 0xa48c1857" ::: "memory");
            break;
        case 29:
            __asm__ volatile(".word 0xa6855857" ::: "memory");
            break;
        case 30:
            __asm__ volatile(".word 0xa88c1857" ::: "memory");
            break;
        case 31:
            __asm__ volatile(".word 0xaa855857" ::: "memory");
            break;
        case 32:
            __asm__ volatile(".word 0xac8c1857" ::: "memory");
            break;
        case 33:
            __asm__ volatile(".word 0xae855857" ::: "memory");
            break;
        case 34:
            __asm__ volatile(".word 0xb08c1857" ::: "memory");
            break;
        case 35:
            __asm__ volatile(".word 0xb2855857" ::: "memory");
            break;
        case 36:
            __asm__ volatile(".word 0xb48c1857" ::: "memory");
            break;
        case 37:
            __asm__ volatile(".word 0xb6855857" ::: "memory");
            break;
        case 38:
            __asm__ volatile(".word 0xb88c1857" ::: "memory");
            break;
        case 39:
            __asm__ volatile(".word 0xba855857" ::: "memory");
            break;
        case 40:
            __asm__ volatile(".word 0xbc8c1857" ::: "memory");
            break;
        case 41:
            __asm__ volatile(".word 0xbe855857" ::: "memory");
            break;
        case 42:
            __asm__ volatile(".word 0xc08c1857" ::: "memory");
            break;
        case 43:
            __asm__ volatile(".word 0xc2855857" ::: "memory");
            break;
        case 44:
            __asm__ volatile(".word 0xc88c1857" ::: "memory");
            break;
        case 45:
            __asm__ volatile(".word 0xca855857" ::: "memory");
            break;
        case 46:
            __asm__ volatile(".word 0xd08c1857" ::: "memory");
            break;
        case 47:
            __asm__ volatile(".word 0xd2855857" ::: "memory");
            break;
        case 48:
            __asm__ volatile(".word 0xd88c1857" ::: "memory");
            break;
        case 49:
            __asm__ volatile(".word 0xda855857" ::: "memory");
            break;
        case 50:
            __asm__ volatile(".word 0xe08c1857" ::: "memory");
            break;
        case 51:
            __asm__ volatile(".word 0xe2855857" ::: "memory");
            break;
        case 52:
            __asm__ volatile(".word 0xf08c1857" ::: "memory");
            break;
        case 53:
            __asm__ volatile(".word 0xf2855857" ::: "memory");
            break;
        case 54:
            __asm__ volatile(".word 0xf48c1857" ::: "memory");
            break;
        case 55:
            __asm__ volatile(".word 0xf6855857" ::: "memory");
            break;
        case 56:
            __asm__ volatile(".word 0xf88c1857" ::: "memory");
            break;
        case 57:
            __asm__ volatile(".word 0xfa855857" ::: "memory");
            break;
        case 58:
            __asm__ volatile(".word 0xfc8c1857" ::: "memory");
            break;
        case 59:
            __asm__ volatile(".word 0xfe855857" ::: "memory");
            break;
        case 60:
            __asm__ volatile(".word 0x38855857" ::: "memory");
            break;
        case 61:
            __asm__ volatile(".word 0x3e855857" ::: "memory");
            break;
        case 62:
            __asm__ volatile(".word 0x42055857" ::: "memory");
            break;
        case 63:
            __asm__ volatile(".word 0x5c855857" ::: "memory");
            break;
        case 64:
            __asm__ volatile(".word 0x74855857" ::: "memory");
            break;
        case 65:
            __asm__ volatile(".word 0x7e855857" ::: "memory");
            break;
        case 66:
            __asm__ volatile(".word 0x84855857" ::: "memory");
            break;
        case 67:
            __asm__ volatile(".word 0x9e855857" ::: "memory");
            break;
        case 68:
            __asm__ volatile(".word 0x4c801857" ::: "memory");
            break;
        case 69:
            __asm__ volatile(".word 0x4e821857" ::: "memory");
            break;
        case 70:
            __asm__ volatile(".word 0x4c829857" ::: "memory");
            break;
        case 71:
            __asm__ volatile(".word 0x4e881857" ::: "memory");
            break;
        case 72:
            __asm__ volatile(".word 0x048192d7" ::: "memory");
            break;
        case 73:
            __asm__ volatile(".word 0x0e8192d7" ::: "memory");
            break;
        case 74:
            __asm__ volatile(".word 0x148192d7" ::: "memory");
            break;
        case 75:
            __asm__ volatile(".word 0x1e8192d7" ::: "memory");
            break;
        case 76:
            __asm__ volatile(".word 0xc48192d7" ::: "memory");
            break;
        case 77:
            __asm__ volatile(".word 0xce8192d7" ::: "memory");
            break;
        case 78:
            __asm__ volatile(".word 0x48801857" ::: "memory");
            break;
        case 79:
            __asm__ volatile(".word 0x4a809857" ::: "memory");
            break;
        case 80:
            __asm__ volatile(".word 0x48811857" ::: "memory");
            break;
        case 81:
            __asm__ volatile(".word 0x4a819857" ::: "memory");
            break;
        case 82:
            __asm__ volatile(".word 0x48831857" ::: "memory");
            break;
        case 83:
            __asm__ volatile(".word 0x4a839857" ::: "memory");
            break;
        case 84:
            __asm__ volatile(".word 0x48841857" ::: "memory");
            break;
        case 85:
            __asm__ volatile(".word 0x4a849857" ::: "memory");
            break;
        case 86:
            __asm__ volatile(".word 0x48851857" ::: "memory");
            break;
        case 87:
            __asm__ volatile(".word 0x4a859857" ::: "memory");
            break;
        case 88:
            __asm__ volatile(".word 0x48861857" ::: "memory");
            break;
        case 89:
            __asm__ volatile(".word 0x4a871857" ::: "memory");
            break;
        case 90:
            __asm__ volatile(".word 0x48879857" ::: "memory");
            break;
        case 91:
            __asm__ volatile(".word 0x4a881857" ::: "memory");
            break;
        case 92:
            __asm__ volatile(".word 0x48889857" ::: "memory");
            break;
        case 93:
            __asm__ volatile(".word 0x4a891857" ::: "memory");
            break;
        case 94:
            __asm__ volatile(".word 0x48899857" ::: "memory");
            break;
        case 95:
            __asm__ volatile(".word 0x4a8a1857" ::: "memory");
            break;
        case 96:
            __asm__ volatile(".word 0x488a9857" ::: "memory");
            break;
        case 97:
            __asm__ volatile(".word 0x4a8b1857" ::: "memory");
            break;
        case 98:
            __asm__ volatile(".word 0x488b9857" ::: "memory");
            break;
        case 99:
            __asm__ volatile(".word 0x5e055857" ::: "memory");
            break;
    }
}
#if VEC_VLEN == 128
static const uint64_t expected_0[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_1[] = {0x4034000040140000ull, 0x4034000040140000ull};
static const uint64_t expected_2[] = {0xbfc800003fa80000ull, 0x3fd000003f900000ull};
static const uint64_t expected_3[] = {
    0x3990bd003910bd00ull, 0x3990bd003910bd00ull, 0x3992bd003912bd00ull, 0x3992bd003912bd00ull};
static const uint64_t expected_4[] = {0x3fd000003f880000ull, 0x3fd000003f880000ull};
static const uint64_t expected_5[] = {0x3fc800003f880000ull, 0x3fc800003f880000ull};
static const uint64_t expected_6[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_7[] = {0x3fc800003fa00000ull, 0x3fc800003fa00000ull};
static const uint64_t expected_8[] = {0x3fc800003f880000ull, 0x3fd000003f900000ull};
static const uint64_t expected_9[] = {
    0x3fc800003f880000ull, 0x3fc800003f880000ull, 0x3fc900003f890000ull, 0x3fc900003f890000ull};
static const uint64_t expected_10[] = {0x3fd00000bf880000ull, 0x3fd00000bf880000ull};
static const uint64_t expected_11[] = {0xbfc800003f880000ull, 0xbfc800003f880000ull};
static const uint64_t expected_12[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_13[] = {0x3fc800003f880000ull, 0x3fc800003f880000ull};
static const uint64_t expected_14[] = {0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_15[] = {0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_16[] = {0x3fd000003f900005ull, 0x3fd000003f900000ull};
static const uint64_t expected_17[] = {0x3fd000003f900003ull, 0x3fd000003f900000ull};
static const uint64_t expected_18[] = {0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_19[] = {0x3fd000003f900005ull, 0x3fd000003f900000ull};
static const uint64_t expected_20[] = {0x3fd000003f900001ull, 0x3fd000003f900000ull};
static const uint64_t expected_21[] = {0x3fd000003f90ffffull, 0x3fd000003f900000ull};
static const uint64_t expected_22[] = {0x3fd000003f650d79ull, 0x3fd000003f650d79ull};
static const uint64_t expected_23[] = {0x3fc3333366066667ull, 0x3fc3333366066667ull};
static const uint64_t expected_24[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_25[] = {0x3ffa00003faa0000ull, 0x3ffa00003faa0000ull};
static const uint64_t expected_26[] = {0x3fd200004780003full, 0x3fd000003f900000ull};
static const uint64_t expected_27[] = {
    0x44630000443f0000ull, 0x44630000443f0000ull, 0x44630000443f0000ull, 0x44630000443f0000ull};
static const uint64_t expected_28[] = {0x3fd00000c0198000ull, 0x3fd00000c0198000ull};
static const uint64_t expected_29[] = {0xbfe00000379c0000ull, 0xbfe00000379c0000ull};
static const uint64_t expected_30[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_31[] = {0x3ef000003eb00000ull, 0x3ef000003eb00000ull};
static const uint64_t expected_32[] = {0x3fb7ffffe01fff03ull, 0x3fd000003f900000ull};
static const uint64_t expected_33[] = {
    0xb7f00000b7b00000ull, 0xb7f00000b7b00000ull, 0xb7f10000b7b10000ull, 0xb7f10000b7b10000ull};
static const uint64_t expected_34[] = {0x3fd000004018c000ull, 0x3fd000004018c000ull};
static const uint64_t expected_35[] = {0x3fdf000067450000ull, 0x3fdf000067450000ull};
static const uint64_t expected_36[] = {
    0x3fd080003f908000ull, 0x3fd080003f908000ull, 0x3fd180003f918000ull, 0x3fd180003f918000ull};
static const uint64_t expected_37[] = {0xc0650000c01d0000ull, 0xc0650000c01d0000ull};
static const uint64_t expected_38[] = {0xbfc700004f73ffc0ull, 0x3fd000003f900000ull};
static const uint64_t expected_39[] = {
    0x37a8000037680000ull, 0x37a8000037680000ull, 0x37a9000037690000ull, 0x37a9000037690000ull};
static const uint64_t expected_40[] = {0x3fd00000be0c0000ull, 0x3fd00000be0c0000ull};
static const uint64_t expected_41[] = {0x3f9000017db00000ull, 0x3f9000017db00000ull};
static const uint64_t expected_42[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_43[] = {
    0x4002800000000000ull, 0x4006800000000000ull, 0x4002800000000000ull, 0x4006800000000000ull};
static const uint64_t expected_44[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull};
static const uint64_t expected_45[] = {0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull};
static const uint64_t expected_46[] = {
    0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd100003f890000ull, 0x3fd100003f890000ull};
static const uint64_t expected_47[] = {
    0x3ff7000007f10000ull, 0x3ff7000007f10000ull, 0x3ff7200007f12000ull, 0x3ff7200007f12000ull};
static const uint64_t expected_48[] = {0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd300003f8b0000ull,
                                       0x3fd300003f8b0000ull};
static const uint64_t expected_49[] = {
    0xbff0fffff80f0000ull, 0xbff0fffff80f0000ull, 0xbff0dffff80ee000ull, 0xbff0dffff80ee000ull};
static const uint64_t expected_50[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull};
static const uint64_t expected_51[] = {0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull};
static const uint64_t expected_52[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_53[] = {
    0x3ff940000fe40000ull, 0x4001a00007f20000ull, 0x3ff980000fe44000ull, 0x4001c00007f22000ull};
static const uint64_t expected_54[] = {0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd30000bf930000ull,
                                       0x3fd30000bf930000ull};
static const uint64_t expected_55[] = {
    0xbff940000fe40000ull, 0xc001a00007f20000ull, 0xbff980000fe44000ull, 0xc001c00007f22000ull};
static const uint64_t expected_56[] = {
    0x3fd00000bf900000ull, 0x3fd00000bf900000ull, 0x3fd10000bf910000ull, 0x3fd10000bf910000ull};
static const uint64_t expected_57[] = {0x3ff13ffff01c0000ull,
                                       0x3ffb3ffff01c0000ull,
                                       0x3ff0fffff01bc000ull,
                                       0x3ffafffff01bc000ull,
                                       0x3ff0e7fff01b8000ull,
                                       0x3ffae7fff01b8000ull,
                                       0x3ff0a7fff01b4000ull,
                                       0x3ffaa7fff01b4000ull};
static const uint64_t expected_58[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_59[] = {
    0xbff13ffff01c0000ull, 0xbffb3ffff01c0000ull, 0xbff0fffff01bc000ull, 0xbffafffff01bc000ull};
static const uint64_t expected_60[] = {
    0x3fd03f883f903d00ull, 0x3fd03f883f903fc8ull, 0x3fd13f893f913fc8ull, 0x3fd13f893f913fc9ull};
static const uint64_t expected_61[] = {0x3f8800003fc80000ull, 0x3fa000003fc80000ull};
static const uint64_t expected_62[] = {0x3ff4000000000000ull, 0x3fd000003f900000ull};
static const uint64_t expected_63[] = {
    0x3fc83d003f883d00ull, 0x3fc83d003f883d00ull, 0x3fc93d003f893d00ull, 0x3fc93d003f893d00ull};
static const uint64_t expected_64[] = {0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_65[] = {0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_66[] = {
    0x3fd07c003f907c00ull, 0x3fd07c003f907c00ull, 0x3fd17c003f917c00ull, 0x3fd17c003f917c00ull};
static const uint64_t expected_67[] = {0xbea000003e400000ull, 0xbea000003e400000ull};
static const uint64_t expected_68[] = {0x3fdbb67b0d0652ebull, 0x3fd000003f900000ull};
static const uint64_t expected_69[] = {
    0x39c07c0039d87c00ull, 0x39c07c0039d87c00ull, 0x39c07c0039d87c00ull, 0x39c07c0039d87c00ull};
static const uint64_t expected_70[] = {0x3fd000003f700000ull, 0x3fd000003f700000ull};
static const uint64_t expected_71[] = {0x0000000000000040ull, 0x0000000000000040ull};
static const uint64_t expected_72[] = {0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_73[] = {0x3fc5000040c8c000ull, 0x3fc500003f850000ull};
static const uint64_t expected_74[] = {0x3fc300003f830000ull, 0x3fc500003f850000ull};
static const uint64_t expected_75[] = {0x3fc500003f853fc8ull, 0x3fc500003f850000ull};
static const uint64_t expected_76[] = {0x3fc500003f830000ull, 0x3fc500003f850000ull};
static const uint64_t expected_77[] = {0x4015980001fc1800ull, 0x3fc500003f850000ull};
static const uint64_t expected_78[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd100003f910000ull, 0x3fd100003f910000ull};
static const uint64_t expected_79[] = {0x0000000200000001ull, 0x0000000200000001ull};
static const uint64_t expected_80[] = {0x43cfe400001fc400ull, 0x3fd000003f900000ull};
static const uint64_t expected_81[] = {
    0x73f9000073f10000ull, 0x73f9000073f10000ull, 0x73f9000073f10000ull, 0x73f9000073f10000ull};
static const uint64_t expected_82[] = {0x3fd0000000000001ull, 0x3fd0000000000001ull};
static const uint64_t expected_83[] = {0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_84[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_85[] = {
    0x0000000000000001ull, 0x0000000000000002ull, 0x0000000000000001ull, 0x0000000000000002ull};
static const uint64_t expected_86[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull};
static const uint64_t expected_87[] = {0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull};
static const uint64_t expected_88[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull};
static const uint64_t expected_89[] = {
    0x0000000000000001ull, 0x0000000000000001ull, 0x0000000000000001ull, 0x0000000000000001ull};
static const uint64_t expected_90[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_91[] = {0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_92[] = {0x3fd000013f900001ull, 0x3fd000013f900001ull};
static const uint64_t expected_93[] = {
    0x5e7f20015e7f2001ull, 0x5e7f24015e7f2401ull, 0x5e7f28015e7f2801ull, 0x5e7f2c015e7f2c01ull};
static const uint64_t expected_94[] = {0x3fd07c003f907c00ull, 0x3fd07c003f907c00ull};
static const uint64_t expected_95[] = {0x3e4000023e400002ull, 0x3e4800023e480002ull};
static const uint64_t expected_96[] = {
    0x3fd03c403f903c40ull, 0x3fd03c483f903c48ull, 0x3fd13c503f913c50ull, 0x3fd13c583f913c58ull};
static const uint64_t expected_97[] = {0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_98[] = {0x3fd000013f900001ull, 0x3fd000013f900001ull};
static const uint64_t expected_99[] = {
    0x3d003d003d003d00ull, 0x3d003d003d003d00ull, 0x3d003d003d003d00ull, 0x3d003d003d003d00ull};
static const struct test_case cases[] = {
    {"add", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_0},
    {"add", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_1},
    {"sub", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_2},
    {"sub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_3},
    {"min", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_4},
    {"min", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_5},
    {"max", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_6},
    {"max", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_7},
    {"sgnj", 24, 16, 1, 3, 0, 0x3ff4000000000000ull, expected_8},
    {"sgnj", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_9},
    {"sgnjn", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_10},
    {"sgnjn", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_11},
    {"sgnjx", 9, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_12},
    {"sgnjx", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_13},
    {"eq", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_14},
    {"eq", 9, 16, 1, 0, 0, 0xffffffffffff3d00ull, expected_15},
    {"le", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_16},
    {"le", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_17},
    {"lt", 9, 16, 1, 3, 0, 0xffffffffffff3d00ull, expected_18},
    {"lt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_19},
    {"ne", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_20},
    {"ne", 9, 16, 1, 1, 0, 0xffffffffffff3d00ull, expected_21},
    {"div", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_22},
    {"div", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_23},
    {"mul", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_24},
    {"mul", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_25},
    {"madd", 24, 16, 1, 1, 1, 0x3ff4000000000000ull, expected_26},
    {"madd", 9, 16, 2, 2, 1, 0xffffffffffff3d00ull, expected_27},
    {"nmadd", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_28},
    {"nmadd", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_29},
    {"msub", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_30},
    {"msub", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_31},
    {"nmsub", 24, 16, 1, 2, 1, 0x3ff4000000000000ull, expected_32},
    {"nmsub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_33},
    {"macc", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_34},
    {"macc", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_35},
    {"nmacc", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_36},
    {"nmacc", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_37},
    {"msac", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_38},
    {"msac", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_39},
    {"nmsac", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_40},
    {"nmsac", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_41},
    {"wadd", 9, 16, 4, 2, 0, 0xffffffffffff3d00ull, expected_42},
    {"wadd", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_43},
    {"wsub", 8, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_44},
    {"wsub", 17, 16, 4, 0, 0, 0xffffffff3fa00000ull, expected_45},
    {"wadd_w", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_46},
    {"wadd_w", 16, 16, 2, 2, 0, 0xffffffff3fa00000ull, expected_47},
    {"wsub_w", 9, 16, 4, 3, 0, 0xffffffffffff3d00ull, expected_48},
    {"wsub_w", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_49},
    {"wmul", 8, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_50},
    {"wmul", 17, 16, 4, 1, 0, 0xffffffff3fa00000ull, expected_51},
    {"wmacc", 8, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_52},
    {"wmacc", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_53},
    {"wnmacc", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_54},
    {"wnmacc", 16, 16, 2, 0, 0, 0xffffffff3fa00000ull, expected_55},
    {"wmsac", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_56},
    {"wmsac", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_57},
    {"wnmsac", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_58},
    {"wnmsac", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_59},
    {"slide1up", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_60},
    {"slide1down", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_61},
    {"mv_s_f", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_62},
    {"merge", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_63},
    {"gt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_64},
    {"ge", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_65},
    {"rdiv", 9, 16, 2, 1, 8, 0xffffffffffff3d00ull, expected_66},
    {"rsub", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_67},
    {"sqrt", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_68},
    {"rsqrt7", 9, 16, 2, 4, 8, 0xffffffffffff3d00ull, expected_69},
    {"rec7", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_70},
    {"class", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_71},
    {"redusum", 8, 5, 1, 2, 0, 0xffffffffffff3d00ull, expected_72},
    {"redosum", 16, 5, 1, 3, 0, 0xffffffff3fa00000ull, expected_73},
    {"redmin", 24, 5, 1, 4, 0, 0x3ff4000000000000ull, expected_74},
    {"redmax", 8, 5, 1, 0, 0, 0xffffffffffff3d00ull, expected_75},
    {"wredusum", 8, 5, 1, 1, 0, 0xffffffffffff3d00ull, expected_76},
    {"wredosum", 16, 5, 1, 2, 0, 0xffffffff3fa00000ull, expected_77},
    {"cvt0", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_78},
    {"cvt1", 16, 16, 1, 4, 1, 0xffffffff3fa00000ull, expected_79},
    {"cvt2", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_80},
    {"cvt3", 9, 16, 2, 1, 1, 0xffffffffffff3d00ull, expected_81},
    {"cvt6", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_82},
    {"cvt7", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_83},
    {"cvt8", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_84},
    {"cvt9", 16, 16, 2, 0, 1, 0xffffffff3fa00000ull, expected_85},
    {"cvt10", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_86},
    {"cvt11", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_87},
    {"cvt12", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_88},
    {"cvt14", 16, 16, 2, 4, 1, 0xffffffff3fa00000ull, expected_89},
    {"cvt15", 9, 16, 4, 0, 0, 0xffffffffffff3d00ull, expected_90},
    {"cvt16", 16, 16, 1, 1, 1, 0xffffffff3fa00000ull, expected_91},
    {"cvt17", 8, 16, 1, 2, 1, 0xffffffffffff3d00ull, expected_92},
    {"cvt18", 17, 16, 2, 3, 1, 0xffffffff3fa00000ull, expected_93},
    {"cvt19", 8, 16, 1, 4, 5, 0xffffffffffff3d00ull, expected_94},
    {"cvt20", 16, 16, 1, 0, 1, 0xffffffff3fa00000ull, expected_95},
    {"cvt21", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_96},
    {"cvt22", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_97},
    {"cvt23", 8, 16, 1, 3, 1, 0xffffffffffff3d00ull, expected_98},
    {"mv_v_f", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_99},
};
#endif
#if VEC_VLEN == 256
static const uint64_t expected_0[] = {0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull};
static const uint64_t expected_1[] = {
    0x4034000040140000ull, 0x4034000040140000ull, 0x4034000040140000ull, 0x4034000040140000ull};
static const uint64_t expected_2[] = {
    0xbfc800003fa80000ull, 0x3fd000003f900000ull, 0xbfc800003fa80000ull, 0x3fd000003f900000ull};
static const uint64_t expected_3[] = {0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull};
static const uint64_t expected_4[] = {
    0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull};
static const uint64_t expected_5[] = {
    0x3fc800003f880000ull, 0x3fc800003f880000ull, 0x3fc800003f880000ull, 0x3fc800003f880000ull};
static const uint64_t expected_6[] = {0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull};
static const uint64_t expected_7[] = {
    0x3fc800003fa00000ull, 0x3fc800003fa00000ull, 0x3fc800003fa00000ull, 0x3fc800003fa00000ull};
static const uint64_t expected_8[] = {
    0x3fc800003f880000ull, 0x3fd000003f900000ull, 0x3fc800003f880000ull, 0x3fd000003f900000ull};
static const uint64_t expected_9[] = {0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull};
static const uint64_t expected_10[] = {
    0x3fd00000bf880000ull, 0x3fd00000bf880000ull, 0x3fd00000bf880000ull, 0x3fd00000bf880000ull};
static const uint64_t expected_11[] = {
    0xbfc800003f880000ull, 0xbfc800003f880000ull, 0xbfc800003f880000ull, 0xbfc800003f880000ull};
static const uint64_t expected_12[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_13[] = {
    0x3fc800003f880000ull, 0x3fc800003f880000ull, 0x3fc800003f880000ull, 0x3fc800003f880000ull};
static const uint64_t expected_14[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_15[] = {
    0x3fd0000000000000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_16[] = {
    0x3fd000003f900055ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_17[] = {
    0x3fd000003f90000full, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_18[] = {
    0x3fd000002a800000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_19[] = {
    0x3fd000003f900055ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_20[] = {
    0x3fd000003f900005ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_21[] = {
    0x3fd00000ffffffffull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_22[] = {
    0x3fd000003f650d79ull, 0x3fd000003f650d79ull, 0x3fd000003f650d79ull, 0x3fd000003f650d79ull};
static const uint64_t expected_23[] = {
    0x3fc3333366066667ull, 0x3fc3333366066667ull, 0x3fc3333366066667ull, 0x3fc3333366066667ull};
static const uint64_t expected_24[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_25[] = {
    0x3ffa00003faa0000ull, 0x3ffa00003faa0000ull, 0x3ffa00003faa0000ull, 0x3ffa00003faa0000ull};
static const uint64_t expected_26[] = {
    0x3fd200004780003full, 0x3fd000003f900000ull, 0x3fd200004780003full, 0x3fd000003f900000ull};
static const uint64_t expected_27[] = {0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull};
static const uint64_t expected_28[] = {
    0x3fd00000c0198000ull, 0x3fd00000c0198000ull, 0x3fd00000c0198000ull, 0x3fd00000c0198000ull};
static const uint64_t expected_29[] = {
    0xbfe00000379c0000ull, 0xbfe00000379c0000ull, 0xbfe00000379c0000ull, 0xbfe00000379c0000ull};
static const uint64_t expected_30[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_31[] = {
    0x3ef000003eb00000ull, 0x3ef000003eb00000ull, 0x3ef000003eb00000ull, 0x3ef000003eb00000ull};
static const uint64_t expected_32[] = {
    0x3fb7ffffe01fff03ull, 0x3fd000003f900000ull, 0x3fb7ffffe01fff03ull, 0x3fd000003f900000ull};
static const uint64_t expected_33[] = {0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull};
static const uint64_t expected_34[] = {
    0x3fd000004018c000ull, 0x3fd000004018c000ull, 0x3fd000004018c000ull, 0x3fd000004018c000ull};
static const uint64_t expected_35[] = {
    0x3fdf000067450000ull, 0x3fdf000067450000ull, 0x3fdf000067450000ull, 0x3fdf000067450000ull};
static const uint64_t expected_36[] = {0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull};
static const uint64_t expected_37[] = {
    0xc0650000c01d0000ull, 0xc0650000c01d0000ull, 0xc0650000c01d0000ull, 0xc0650000c01d0000ull};
static const uint64_t expected_38[] = {
    0xbfc700004f73ffc0ull, 0x3fd000003f900000ull, 0xbfc700004f73ffc0ull, 0x3fd000003f900000ull};
static const uint64_t expected_39[] = {0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull};
static const uint64_t expected_40[] = {
    0x3fd00000be0c0000ull, 0x3fd00000be0c0000ull, 0x3fd00000be0c0000ull, 0x3fd00000be0c0000ull};
static const uint64_t expected_41[] = {
    0x3f9000017db00000ull, 0x3f9000017db00000ull, 0x3f9000017db00000ull, 0x3f9000017db00000ull};
static const uint64_t expected_42[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_43[] = {0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull};
static const uint64_t expected_44[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_45[] = {0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc8000000000000ull,
                                       0x3fd4000000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull,
                                       0xbfc7000000000000ull,
                                       0x3fd4800000000000ull};
static const uint64_t expected_46[] = {0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull};
static const uint64_t expected_47[] = {0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull};
static const uint64_t expected_48[] = {0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd200003f8a0000ull,
                                       0x3fd300003f8b0000ull,
                                       0x3fd300003f8b0000ull,
                                       0x3fd300003f8b0000ull,
                                       0x3fd300003f8b0000ull};
static const uint64_t expected_49[] = {0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull};
static const uint64_t expected_50[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_51[] = {0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5400000000000ull,
                                       0x3fff400000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull,
                                       0x3ff5680000000000ull,
                                       0x3fff680000000000ull};
static const uint64_t expected_52[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_53[] = {0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull};
static const uint64_t expected_54[] = {0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd20000bf920000ull,
                                       0x3fd30000bf930000ull,
                                       0x3fd30000bf930000ull,
                                       0x3fd30000bf930000ull,
                                       0x3fd30000bf930000ull};
static const uint64_t expected_55[] = {0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull};
static const uint64_t expected_56[] = {0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull};
static const uint64_t expected_57[] = {0x3ff13ffff01c0000ull,
                                       0x3ffb3ffff01c0000ull,
                                       0x3ff13ffff01c0000ull,
                                       0x3ffb3ffff01c0000ull,
                                       0x3ff0fffff01bc000ull,
                                       0x3ffafffff01bc000ull,
                                       0x3ff0fffff01bc000ull,
                                       0x3ffafffff01bc000ull,
                                       0x3ff0e7fff01b8000ull,
                                       0x3ffae7fff01b8000ull,
                                       0x3ff0e7fff01b8000ull,
                                       0x3ffae7fff01b8000ull,
                                       0x3ff0a7fff01b4000ull,
                                       0x3ffaa7fff01b4000ull,
                                       0x3ff0a7fff01b4000ull,
                                       0x3ffaa7fff01b4000ull};
static const uint64_t expected_58[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_59[] = {0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull};
static const uint64_t expected_60[] = {0x3fd03f883f903d00ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd13f893f913fc8ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull};
static const uint64_t expected_61[] = {
    0x3f8800003fc80000ull, 0x3f8800003fc80000ull, 0x3f8800003fc80000ull, 0x3fa000003fc80000ull};
static const uint64_t expected_62[] = {
    0x3ff4000000000000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_63[] = {0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull};
static const uint64_t expected_64[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_65[] = {
    0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull, 0x3fd000003f900000ull};
static const uint64_t expected_66[] = {0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull};
static const uint64_t expected_67[] = {
    0xbea000003e400000ull, 0xbea000003e400000ull, 0xbea000003e400000ull, 0xbea000003e400000ull};
static const uint64_t expected_68[] = {
    0x3fdbb67b0d0652ebull, 0x3fd000003f900000ull, 0x3fdbb67b0d0652ebull, 0x3fd000003f900000ull};
static const uint64_t expected_69[] = {0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull};
static const uint64_t expected_70[] = {
    0x3fd000003f700000ull, 0x3fd000003f700000ull, 0x3fd000003f700000ull, 0x3fd000003f700000ull};
static const uint64_t expected_71[] = {
    0x0000000000000040ull, 0x0000000000000040ull, 0x0000000000000040ull, 0x0000000000000040ull};
static const uint64_t expected_72[] = {
    0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_73[] = {
    0x3fc5000041386000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_74[] = {
    0x3fc300003f830000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_75[] = {
    0x3fc500003f853fc8ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_76[] = {
    0x3fc500003f830000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_77[] = {
    0x40254c0000fe0c00ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull, 0x3fc500003f850000ull};
static const uint64_t expected_78[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_79[] = {
    0x0000000200000001ull, 0x0000000200000001ull, 0x0000000200000001ull, 0x0000000200000001ull};
static const uint64_t expected_80[] = {
    0x43cfe400001fc400ull, 0x3fd000003f900000ull, 0x43cfe400001fc400ull, 0x3fd000003f900000ull};
static const uint64_t expected_81[] = {0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull};
static const uint64_t expected_82[] = {
    0x3fd0000000000001ull, 0x3fd0000000000001ull, 0x3fd0000000000001ull, 0x3fd0000000000001ull};
static const uint64_t expected_83[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_84[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_85[] = {0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull};
static const uint64_t expected_86[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_87[] = {0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc40000000000ull,
                                       0x41cfe40000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull,
                                       0x41cfc48000000000ull,
                                       0x41cfe48000000000ull};
static const uint64_t expected_88[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_89[] = {0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull};
static const uint64_t expected_90[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd2000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull,
                                       0x3fd3000000000000ull};
static const uint64_t expected_91[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_92[] = {
    0x3fd000013f900001ull, 0x3fd000013f900001ull, 0x3fd000013f900001ull, 0x3fd000013f900001ull};
static const uint64_t expected_93[] = {0x5e7f20015e7f2001ull,
                                       0x5e7f20015e7f2001ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f2c015e7f2c01ull,
                                       0x5e7f2c015e7f2c01ull};
static const uint64_t expected_94[] = {
    0x3fd07c003f907c00ull, 0x3fd07c003f907c00ull, 0x3fd07c003f907c00ull, 0x3fd07c003f907c00ull};
static const uint64_t expected_95[] = {
    0x3e4000023e400002ull, 0x3e4000023e400002ull, 0x3e4800023e480002ull, 0x3e4800023e480002ull};
static const uint64_t expected_96[] = {0x3fd03c403f903c40ull,
                                       0x3fd03c403f903c40ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c583f913c58ull,
                                       0x3fd13c583f913c58ull};
static const uint64_t expected_97[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_98[] = {
    0x3fd000013f900001ull, 0x3fd000013f900001ull, 0x3fd000013f900001ull, 0x3fd000013f900001ull};
static const uint64_t expected_99[] = {0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull};
static const struct test_case cases[] = {
    {"add", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_0},
    {"add", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_1},
    {"sub", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_2},
    {"sub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_3},
    {"min", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_4},
    {"min", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_5},
    {"max", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_6},
    {"max", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_7},
    {"sgnj", 24, 16, 1, 3, 0, 0x3ff4000000000000ull, expected_8},
    {"sgnj", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_9},
    {"sgnjn", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_10},
    {"sgnjn", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_11},
    {"sgnjx", 9, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_12},
    {"sgnjx", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_13},
    {"eq", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_14},
    {"eq", 9, 16, 1, 0, 0, 0xffffffffffff3d00ull, expected_15},
    {"le", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_16},
    {"le", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_17},
    {"lt", 9, 16, 1, 3, 0, 0xffffffffffff3d00ull, expected_18},
    {"lt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_19},
    {"ne", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_20},
    {"ne", 9, 16, 1, 1, 0, 0xffffffffffff3d00ull, expected_21},
    {"div", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_22},
    {"div", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_23},
    {"mul", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_24},
    {"mul", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_25},
    {"madd", 24, 16, 1, 1, 1, 0x3ff4000000000000ull, expected_26},
    {"madd", 9, 16, 2, 2, 1, 0xffffffffffff3d00ull, expected_27},
    {"nmadd", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_28},
    {"nmadd", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_29},
    {"msub", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_30},
    {"msub", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_31},
    {"nmsub", 24, 16, 1, 2, 1, 0x3ff4000000000000ull, expected_32},
    {"nmsub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_33},
    {"macc", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_34},
    {"macc", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_35},
    {"nmacc", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_36},
    {"nmacc", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_37},
    {"msac", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_38},
    {"msac", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_39},
    {"nmsac", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_40},
    {"nmsac", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_41},
    {"wadd", 9, 16, 4, 2, 0, 0xffffffffffff3d00ull, expected_42},
    {"wadd", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_43},
    {"wsub", 8, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_44},
    {"wsub", 17, 16, 4, 0, 0, 0xffffffff3fa00000ull, expected_45},
    {"wadd_w", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_46},
    {"wadd_w", 16, 16, 2, 2, 0, 0xffffffff3fa00000ull, expected_47},
    {"wsub_w", 9, 16, 4, 3, 0, 0xffffffffffff3d00ull, expected_48},
    {"wsub_w", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_49},
    {"wmul", 8, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_50},
    {"wmul", 17, 16, 4, 1, 0, 0xffffffff3fa00000ull, expected_51},
    {"wmacc", 8, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_52},
    {"wmacc", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_53},
    {"wnmacc", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_54},
    {"wnmacc", 16, 16, 2, 0, 0, 0xffffffff3fa00000ull, expected_55},
    {"wmsac", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_56},
    {"wmsac", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_57},
    {"wnmsac", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_58},
    {"wnmsac", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_59},
    {"slide1up", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_60},
    {"slide1down", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_61},
    {"mv_s_f", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_62},
    {"merge", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_63},
    {"gt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_64},
    {"ge", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_65},
    {"rdiv", 9, 16, 2, 1, 8, 0xffffffffffff3d00ull, expected_66},
    {"rsub", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_67},
    {"sqrt", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_68},
    {"rsqrt7", 9, 16, 2, 4, 8, 0xffffffffffff3d00ull, expected_69},
    {"rec7", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_70},
    {"class", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_71},
    {"redusum", 8, 5, 1, 2, 0, 0xffffffffffff3d00ull, expected_72},
    {"redosum", 16, 5, 1, 3, 0, 0xffffffff3fa00000ull, expected_73},
    {"redmin", 24, 5, 1, 4, 0, 0x3ff4000000000000ull, expected_74},
    {"redmax", 8, 5, 1, 0, 0, 0xffffffffffff3d00ull, expected_75},
    {"wredusum", 8, 5, 1, 1, 0, 0xffffffffffff3d00ull, expected_76},
    {"wredosum", 16, 5, 1, 2, 0, 0xffffffff3fa00000ull, expected_77},
    {"cvt0", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_78},
    {"cvt1", 16, 16, 1, 4, 1, 0xffffffff3fa00000ull, expected_79},
    {"cvt2", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_80},
    {"cvt3", 9, 16, 2, 1, 1, 0xffffffffffff3d00ull, expected_81},
    {"cvt6", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_82},
    {"cvt7", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_83},
    {"cvt8", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_84},
    {"cvt9", 16, 16, 2, 0, 1, 0xffffffff3fa00000ull, expected_85},
    {"cvt10", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_86},
    {"cvt11", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_87},
    {"cvt12", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_88},
    {"cvt14", 16, 16, 2, 4, 1, 0xffffffff3fa00000ull, expected_89},
    {"cvt15", 9, 16, 4, 0, 0, 0xffffffffffff3d00ull, expected_90},
    {"cvt16", 16, 16, 1, 1, 1, 0xffffffff3fa00000ull, expected_91},
    {"cvt17", 8, 16, 1, 2, 1, 0xffffffffffff3d00ull, expected_92},
    {"cvt18", 17, 16, 2, 3, 1, 0xffffffff3fa00000ull, expected_93},
    {"cvt19", 8, 16, 1, 4, 5, 0xffffffffffff3d00ull, expected_94},
    {"cvt20", 16, 16, 1, 0, 1, 0xffffffff3fa00000ull, expected_95},
    {"cvt21", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_96},
    {"cvt22", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_97},
    {"cvt23", 8, 16, 1, 3, 1, 0xffffffffffff3d00ull, expected_98},
    {"mv_v_f", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_99},
};
#endif
#if VEC_VLEN == 512
static const uint64_t expected_0[] = {0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull};
static const uint64_t expected_1[] = {0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull,
                                      0x4034000040140000ull};
static const uint64_t expected_2[] = {0xbfc800003fa80000ull,
                                      0x3fd000003f900000ull,
                                      0xbfc800003fa80000ull,
                                      0x3fd000003f900000ull,
                                      0xbfc800003fa80000ull,
                                      0x3fd000003f900000ull,
                                      0xbfc800003fa80000ull,
                                      0x3fd000003f900000ull};
static const uint64_t expected_3[] = {0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3990bd003910bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull,
                                      0x3992bd003912bd00ull};
static const uint64_t expected_4[] = {0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull,
                                      0x3fd000003f880000ull};
static const uint64_t expected_5[] = {0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull};
static const uint64_t expected_6[] = {0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd000003f900000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull,
                                      0x3fd100003f910000ull};
static const uint64_t expected_7[] = {0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull,
                                      0x3fc800003fa00000ull};
static const uint64_t expected_8[] = {0x3fc800003f880000ull,
                                      0x3fd000003f900000ull,
                                      0x3fc800003f880000ull,
                                      0x3fd000003f900000ull,
                                      0x3fc800003f880000ull,
                                      0x3fd000003f900000ull,
                                      0x3fc800003f880000ull,
                                      0x3fd000003f900000ull};
static const uint64_t expected_9[] = {0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc800003f880000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull,
                                      0x3fc900003f890000ull};
static const uint64_t expected_10[] = {0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull,
                                       0x3fd00000bf880000ull};
static const uint64_t expected_11[] = {0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull,
                                       0xbfc800003f880000ull};
static const uint64_t expected_12[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_13[] = {0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull,
                                       0x3fc800003f880000ull};
static const uint64_t expected_14[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_15[] = {0x0000000000000000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_16[] = {0x3fd000003f905555ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_17[] = {0x3fd000003f9000ffull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_18[] = {0x2a8000002a800000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_19[] = {0x3fd000003f905555ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_20[] = {0x3fd000003f900055ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_21[] = {0xffffffffffffffffull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_22[] = {0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull,
                                       0x3fd000003f650d79ull};
static const uint64_t expected_23[] = {0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull,
                                       0x3fc3333366066667ull};
static const uint64_t expected_24[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_25[] = {0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull,
                                       0x3ffa00003faa0000ull};
static const uint64_t expected_26[] = {0x3fd200004780003full,
                                       0x3fd000003f900000ull,
                                       0x3fd200004780003full,
                                       0x3fd000003f900000ull,
                                       0x3fd200004780003full,
                                       0x3fd000003f900000ull,
                                       0x3fd200004780003full,
                                       0x3fd000003f900000ull};
static const uint64_t expected_27[] = {0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull,
                                       0x44630000443f0000ull};
static const uint64_t expected_28[] = {0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull,
                                       0x3fd00000c0198000ull};
static const uint64_t expected_29[] = {0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull,
                                       0xbfe00000379c0000ull};
static const uint64_t expected_30[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_31[] = {0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull,
                                       0x3ef000003eb00000ull};
static const uint64_t expected_32[] = {0x3fb7ffffe01fff03ull,
                                       0x3fd000003f900000ull,
                                       0x3fb7ffffe01fff03ull,
                                       0x3fd000003f900000ull,
                                       0x3fb7ffffe01fff03ull,
                                       0x3fd000003f900000ull,
                                       0x3fb7ffffe01fff03ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_33[] = {0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f00000b7b00000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull,
                                       0xb7f10000b7b10000ull};
static const uint64_t expected_34[] = {0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull,
                                       0x3fd000004018c000ull};
static const uint64_t expected_35[] = {0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull,
                                       0x3fdf000067450000ull};
static const uint64_t expected_36[] = {0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd080003f908000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull,
                                       0x3fd180003f918000ull};
static const uint64_t expected_37[] = {0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull,
                                       0xc0650000c01d0000ull};
static const uint64_t expected_38[] = {0xbfc700004f73ffc0ull,
                                       0x3fd000003f900000ull,
                                       0xbfc700004f73ffc0ull,
                                       0x3fd000003f900000ull,
                                       0xbfc700004f73ffc0ull,
                                       0x3fd000003f900000ull,
                                       0xbfc700004f73ffc0ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_39[] = {0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a8000037680000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull,
                                       0x37a9000037690000ull};
static const uint64_t expected_40[] = {0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull,
                                       0x3fd00000be0c0000ull};
static const uint64_t expected_41[] = {0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull,
                                       0x3f9000017db00000ull};
static const uint64_t expected_42[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull};
static const uint64_t expected_43[] = {0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull,
                                       0x4002800000000000ull,
                                       0x4006800000000000ull};
static const uint64_t expected_44[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_45[] = {
    0xbfc8000000000000ull, 0x3fd4000000000000ull, 0xbfc8000000000000ull, 0x3fd4000000000000ull,
    0xbfc8000000000000ull, 0x3fd4000000000000ull, 0xbfc8000000000000ull, 0x3fd4000000000000ull,
    0xbfc8000000000000ull, 0x3fd4000000000000ull, 0xbfc8000000000000ull, 0x3fd4000000000000ull,
    0xbfc8000000000000ull, 0x3fd4000000000000ull, 0xbfc8000000000000ull, 0x3fd4000000000000ull,
    0xbfc7000000000000ull, 0x3fd4800000000000ull, 0xbfc7000000000000ull, 0x3fd4800000000000ull,
    0xbfc7000000000000ull, 0x3fd4800000000000ull, 0xbfc7000000000000ull, 0x3fd4800000000000ull,
    0xbfc7000000000000ull, 0x3fd4800000000000ull, 0xbfc7000000000000ull, 0x3fd4800000000000ull,
    0xbfc7000000000000ull, 0x3fd4800000000000ull, 0xbfc7000000000000ull, 0x3fd4800000000000ull};
static const uint64_t expected_46[] = {0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd000003f880000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull,
                                       0x3fd100003f890000ull};
static const uint64_t expected_47[] = {0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7000007f10000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull,
                                       0x3ff7200007f12000ull};
static const uint64_t expected_48[] = {
    0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull,
    0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull, 0x3fd000003f880000ull,
    0x3fd100003f890000ull, 0x3fd100003f890000ull, 0x3fd100003f890000ull, 0x3fd100003f890000ull,
    0x3fd100003f890000ull, 0x3fd100003f890000ull, 0x3fd100003f890000ull, 0x3fd100003f890000ull,
    0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull,
    0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull, 0x3fd200003f8a0000ull,
    0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull,
    0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull, 0x3fd300003f8b0000ull};
static const uint64_t expected_49[] = {0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0fffff80f0000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull,
                                       0xbff0dffff80ee000ull};
static const uint64_t expected_50[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_51[] = {
    0x3ff5400000000000ull, 0x3fff400000000000ull, 0x3ff5400000000000ull, 0x3fff400000000000ull,
    0x3ff5400000000000ull, 0x3fff400000000000ull, 0x3ff5400000000000ull, 0x3fff400000000000ull,
    0x3ff5400000000000ull, 0x3fff400000000000ull, 0x3ff5400000000000ull, 0x3fff400000000000ull,
    0x3ff5400000000000ull, 0x3fff400000000000ull, 0x3ff5400000000000ull, 0x3fff400000000000ull,
    0x3ff5680000000000ull, 0x3fff680000000000ull, 0x3ff5680000000000ull, 0x3fff680000000000ull,
    0x3ff5680000000000ull, 0x3fff680000000000ull, 0x3ff5680000000000ull, 0x3fff680000000000ull,
    0x3ff5680000000000ull, 0x3fff680000000000ull, 0x3ff5680000000000ull, 0x3fff680000000000ull,
    0x3ff5680000000000ull, 0x3fff680000000000ull, 0x3ff5680000000000ull, 0x3fff680000000000ull};
static const uint64_t expected_52[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_53[] = {0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff940000fe40000ull,
                                       0x4001a00007f20000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull,
                                       0x3ff980000fe44000ull,
                                       0x4001c00007f22000ull};
static const uint64_t expected_54[] = {
    0x3fd00000bf900000ull, 0x3fd00000bf900000ull, 0x3fd00000bf900000ull, 0x3fd00000bf900000ull,
    0x3fd00000bf900000ull, 0x3fd00000bf900000ull, 0x3fd00000bf900000ull, 0x3fd00000bf900000ull,
    0x3fd10000bf910000ull, 0x3fd10000bf910000ull, 0x3fd10000bf910000ull, 0x3fd10000bf910000ull,
    0x3fd10000bf910000ull, 0x3fd10000bf910000ull, 0x3fd10000bf910000ull, 0x3fd10000bf910000ull,
    0x3fd20000bf920000ull, 0x3fd20000bf920000ull, 0x3fd20000bf920000ull, 0x3fd20000bf920000ull,
    0x3fd20000bf920000ull, 0x3fd20000bf920000ull, 0x3fd20000bf920000ull, 0x3fd20000bf920000ull,
    0x3fd30000bf930000ull, 0x3fd30000bf930000ull, 0x3fd30000bf930000ull, 0x3fd30000bf930000ull,
    0x3fd30000bf930000ull, 0x3fd30000bf930000ull, 0x3fd30000bf930000ull, 0x3fd30000bf930000ull};
static const uint64_t expected_55[] = {0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff940000fe40000ull,
                                       0xc001a00007f20000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull,
                                       0xbff980000fe44000ull,
                                       0xc001c00007f22000ull};
static const uint64_t expected_56[] = {0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd00000bf900000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull,
                                       0x3fd10000bf910000ull};
static const uint64_t expected_57[] = {
    0x3ff13ffff01c0000ull, 0x3ffb3ffff01c0000ull, 0x3ff13ffff01c0000ull, 0x3ffb3ffff01c0000ull,
    0x3ff13ffff01c0000ull, 0x3ffb3ffff01c0000ull, 0x3ff13ffff01c0000ull, 0x3ffb3ffff01c0000ull,
    0x3ff0fffff01bc000ull, 0x3ffafffff01bc000ull, 0x3ff0fffff01bc000ull, 0x3ffafffff01bc000ull,
    0x3ff0fffff01bc000ull, 0x3ffafffff01bc000ull, 0x3ff0fffff01bc000ull, 0x3ffafffff01bc000ull,
    0x3ff0e7fff01b8000ull, 0x3ffae7fff01b8000ull, 0x3ff0e7fff01b8000ull, 0x3ffae7fff01b8000ull,
    0x3ff0e7fff01b8000ull, 0x3ffae7fff01b8000ull, 0x3ff0e7fff01b8000ull, 0x3ffae7fff01b8000ull,
    0x3ff0a7fff01b4000ull, 0x3ffaa7fff01b4000ull, 0x3ff0a7fff01b4000ull, 0x3ffaa7fff01b4000ull,
    0x3ff0a7fff01b4000ull, 0x3ffaa7fff01b4000ull, 0x3ff0a7fff01b4000ull, 0x3ffaa7fff01b4000ull};
static const uint64_t expected_58[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_59[] = {0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff13ffff01c0000ull,
                                       0xbffb3ffff01c0000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull,
                                       0xbff0fffff01bc000ull,
                                       0xbffafffff01bc000ull};
static const uint64_t expected_60[] = {0x3fd03f883f903d00ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd03f883f903fc8ull,
                                       0x3fd13f893f913fc8ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull,
                                       0x3fd13f893f913fc9ull};
static const uint64_t expected_61[] = {0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3f8800003fc80000ull,
                                       0x3fa000003fc80000ull};
static const uint64_t expected_62[] = {0x3ff4000000000000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_63[] = {0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc83d003f883d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull,
                                       0x3fc93d003f893d00ull};
static const uint64_t expected_64[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_65[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_66[] = {0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull,
                                       0x3fd17c003f917c00ull};
static const uint64_t expected_67[] = {0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull,
                                       0xbea000003e400000ull};
static const uint64_t expected_68[] = {0x3fdbb67b0d0652ebull,
                                       0x3fd000003f900000ull,
                                       0x3fdbb67b0d0652ebull,
                                       0x3fd000003f900000ull,
                                       0x3fdbb67b0d0652ebull,
                                       0x3fd000003f900000ull,
                                       0x3fdbb67b0d0652ebull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_69[] = {0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull,
                                       0x39c07c0039d87c00ull};
static const uint64_t expected_70[] = {0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull,
                                       0x3fd000003f700000ull};
static const uint64_t expected_71[] = {0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull,
                                       0x0000000000000040ull};
static const uint64_t expected_72[] = {0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_73[] = {0x3fc5000041b03000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_74[] = {0x3fc300003f830000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_75[] = {0x3fc500003f853fc8ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_76[] = {0x3fc500003f830000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_77[] = {0x40352600007f0600ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull,
                                       0x3fc500003f850000ull};
static const uint64_t expected_78[] = {0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd000003f900000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull,
                                       0x3fd100003f910000ull};
static const uint64_t expected_79[] = {0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull,
                                       0x0000000200000001ull};
static const uint64_t expected_80[] = {0x43cfe400001fc400ull,
                                       0x3fd000003f900000ull,
                                       0x43cfe400001fc400ull,
                                       0x3fd000003f900000ull,
                                       0x43cfe400001fc400ull,
                                       0x3fd000003f900000ull,
                                       0x43cfe400001fc400ull,
                                       0x3fd000003f900000ull};
static const uint64_t expected_81[] = {0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull,
                                       0x73f9000073f10000ull};
static const uint64_t expected_82[] = {0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull,
                                       0x3fd0000000000001ull};
static const uint64_t expected_83[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_84[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull};
static const uint64_t expected_85[] = {0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull,
                                       0x0000000000000001ull,
                                       0x0000000000000002ull};
static const uint64_t expected_86[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_87[] = {
    0x41cfc40000000000ull, 0x41cfe40000000000ull, 0x41cfc40000000000ull, 0x41cfe40000000000ull,
    0x41cfc40000000000ull, 0x41cfe40000000000ull, 0x41cfc40000000000ull, 0x41cfe40000000000ull,
    0x41cfc40000000000ull, 0x41cfe40000000000ull, 0x41cfc40000000000ull, 0x41cfe40000000000ull,
    0x41cfc40000000000ull, 0x41cfe40000000000ull, 0x41cfc40000000000ull, 0x41cfe40000000000ull,
    0x41cfc48000000000ull, 0x41cfe48000000000ull, 0x41cfc48000000000ull, 0x41cfe48000000000ull,
    0x41cfc48000000000ull, 0x41cfe48000000000ull, 0x41cfc48000000000ull, 0x41cfe48000000000ull,
    0x41cfc48000000000ull, 0x41cfe48000000000ull, 0x41cfc48000000000ull, 0x41cfe48000000000ull,
    0x41cfc48000000000ull, 0x41cfe48000000000ull, 0x41cfc48000000000ull, 0x41cfe48000000000ull};
static const uint64_t expected_88[] = {0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd0000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull,
                                       0x3fd1000000000000ull};
static const uint64_t expected_89[] = {0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull,
                                       0x0000000000000001ull};
static const uint64_t expected_90[] = {
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull, 0x3fd0000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull, 0x3fd1000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull, 0x3fd2000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull,
    0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull, 0x3fd3000000000000ull};
static const uint64_t expected_91[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_92[] = {0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull};
static const uint64_t expected_93[] = {0x5e7f20015e7f2001ull,
                                       0x5e7f20015e7f2001ull,
                                       0x5e7f20015e7f2001ull,
                                       0x5e7f20015e7f2001ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f24015e7f2401ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f28015e7f2801ull,
                                       0x5e7f2c015e7f2c01ull,
                                       0x5e7f2c015e7f2c01ull,
                                       0x5e7f2c015e7f2c01ull,
                                       0x5e7f2c015e7f2c01ull};
static const uint64_t expected_94[] = {0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull,
                                       0x3fd07c003f907c00ull};
static const uint64_t expected_95[] = {0x3e4000023e400002ull,
                                       0x3e4000023e400002ull,
                                       0x3e4000023e400002ull,
                                       0x3e4000023e400002ull,
                                       0x3e4800023e480002ull,
                                       0x3e4800023e480002ull,
                                       0x3e4800023e480002ull,
                                       0x3e4800023e480002ull};
static const uint64_t expected_96[] = {0x3fd03c403f903c40ull,
                                       0x3fd03c403f903c40ull,
                                       0x3fd03c403f903c40ull,
                                       0x3fd03c403f903c40ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd03c483f903c48ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c503f913c50ull,
                                       0x3fd13c583f913c58ull,
                                       0x3fd13c583f913c58ull,
                                       0x3fd13c583f913c58ull,
                                       0x3fd13c583f913c58ull};
static const uint64_t expected_97[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_98[] = {0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull,
                                       0x3fd000013f900001ull};
static const uint64_t expected_99[] = {0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull,
                                       0x3d003d003d003d00ull};
static const struct test_case cases[] = {
    {"add", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_0},
    {"add", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_1},
    {"sub", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_2},
    {"sub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_3},
    {"min", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_4},
    {"min", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_5},
    {"max", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_6},
    {"max", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_7},
    {"sgnj", 24, 16, 1, 3, 0, 0x3ff4000000000000ull, expected_8},
    {"sgnj", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_9},
    {"sgnjn", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_10},
    {"sgnjn", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_11},
    {"sgnjx", 9, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_12},
    {"sgnjx", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_13},
    {"eq", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_14},
    {"eq", 9, 16, 1, 0, 0, 0xffffffffffff3d00ull, expected_15},
    {"le", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_16},
    {"le", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_17},
    {"lt", 9, 16, 1, 3, 0, 0xffffffffffff3d00ull, expected_18},
    {"lt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_19},
    {"ne", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_20},
    {"ne", 9, 16, 1, 1, 0, 0xffffffffffff3d00ull, expected_21},
    {"div", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_22},
    {"div", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_23},
    {"mul", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_24},
    {"mul", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_25},
    {"madd", 24, 16, 1, 1, 1, 0x3ff4000000000000ull, expected_26},
    {"madd", 9, 16, 2, 2, 1, 0xffffffffffff3d00ull, expected_27},
    {"nmadd", 16, 16, 1, 3, 0, 0xffffffff3fa00000ull, expected_28},
    {"nmadd", 24, 16, 1, 4, 0, 0x3ff4000000000000ull, expected_29},
    {"msub", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_30},
    {"msub", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_31},
    {"nmsub", 24, 16, 1, 2, 1, 0x3ff4000000000000ull, expected_32},
    {"nmsub", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_33},
    {"macc", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_34},
    {"macc", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_35},
    {"nmacc", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_36},
    {"nmacc", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_37},
    {"msac", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_38},
    {"msac", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_39},
    {"nmsac", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_40},
    {"nmsac", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_41},
    {"wadd", 9, 16, 4, 2, 0, 0xffffffffffff3d00ull, expected_42},
    {"wadd", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_43},
    {"wsub", 8, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_44},
    {"wsub", 17, 16, 4, 0, 0, 0xffffffff3fa00000ull, expected_45},
    {"wadd_w", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_46},
    {"wadd_w", 16, 16, 2, 2, 0, 0xffffffff3fa00000ull, expected_47},
    {"wsub_w", 9, 16, 4, 3, 0, 0xffffffffffff3d00ull, expected_48},
    {"wsub_w", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_49},
    {"wmul", 8, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_50},
    {"wmul", 17, 16, 4, 1, 0, 0xffffffff3fa00000ull, expected_51},
    {"wmacc", 8, 16, 2, 2, 0, 0xffffffffffff3d00ull, expected_52},
    {"wmacc", 16, 16, 2, 3, 0, 0xffffffff3fa00000ull, expected_53},
    {"wnmacc", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_54},
    {"wnmacc", 16, 16, 2, 0, 0, 0xffffffff3fa00000ull, expected_55},
    {"wmsac", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_56},
    {"wmsac", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_57},
    {"wnmsac", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_58},
    {"wnmsac", 16, 16, 2, 4, 0, 0xffffffff3fa00000ull, expected_59},
    {"slide1up", 9, 16, 2, 0, 0, 0xffffffffffff3d00ull, expected_60},
    {"slide1down", 16, 16, 1, 1, 0, 0xffffffff3fa00000ull, expected_61},
    {"mv_s_f", 24, 16, 1, 2, 0, 0x3ff4000000000000ull, expected_62},
    {"merge", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_63},
    {"gt", 16, 16, 1, 4, 0, 0xffffffff3fa00000ull, expected_64},
    {"ge", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_65},
    {"rdiv", 9, 16, 2, 1, 8, 0xffffffffffff3d00ull, expected_66},
    {"rsub", 16, 16, 1, 2, 0, 0xffffffff3fa00000ull, expected_67},
    {"sqrt", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_68},
    {"rsqrt7", 9, 16, 2, 4, 8, 0xffffffffffff3d00ull, expected_69},
    {"rec7", 16, 16, 1, 0, 0, 0xffffffff3fa00000ull, expected_70},
    {"class", 24, 16, 1, 1, 0, 0x3ff4000000000000ull, expected_71},
    {"redusum", 8, 5, 1, 2, 0, 0xffffffffffff3d00ull, expected_72},
    {"redosum", 16, 5, 1, 3, 0, 0xffffffff3fa00000ull, expected_73},
    {"redmin", 24, 5, 1, 4, 0, 0x3ff4000000000000ull, expected_74},
    {"redmax", 8, 5, 1, 0, 0, 0xffffffffffff3d00ull, expected_75},
    {"wredusum", 8, 5, 1, 1, 0, 0xffffffffffff3d00ull, expected_76},
    {"wredosum", 16, 5, 1, 2, 0, 0xffffffff3fa00000ull, expected_77},
    {"cvt0", 9, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_78},
    {"cvt1", 16, 16, 1, 4, 1, 0xffffffff3fa00000ull, expected_79},
    {"cvt2", 24, 16, 1, 0, 0, 0x3ff4000000000000ull, expected_80},
    {"cvt3", 9, 16, 2, 1, 1, 0xffffffffffff3d00ull, expected_81},
    {"cvt6", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_82},
    {"cvt7", 24, 16, 1, 3, 1, 0x3ff4000000000000ull, expected_83},
    {"cvt8", 9, 16, 4, 4, 0, 0xffffffffffff3d00ull, expected_84},
    {"cvt9", 16, 16, 2, 0, 1, 0xffffffff3fa00000ull, expected_85},
    {"cvt10", 8, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_86},
    {"cvt11", 17, 16, 4, 2, 0, 0xffffffff3fa00000ull, expected_87},
    {"cvt12", 8, 16, 2, 3, 0, 0xffffffffffff3d00ull, expected_88},
    {"cvt14", 16, 16, 2, 4, 1, 0xffffffff3fa00000ull, expected_89},
    {"cvt15", 9, 16, 4, 0, 0, 0xffffffffffff3d00ull, expected_90},
    {"cvt16", 16, 16, 1, 1, 1, 0xffffffff3fa00000ull, expected_91},
    {"cvt17", 8, 16, 1, 2, 1, 0xffffffffffff3d00ull, expected_92},
    {"cvt18", 17, 16, 2, 3, 1, 0xffffffff3fa00000ull, expected_93},
    {"cvt19", 8, 16, 1, 4, 5, 0xffffffffffff3d00ull, expected_94},
    {"cvt20", 16, 16, 1, 0, 1, 0xffffffff3fa00000ull, expected_95},
    {"cvt21", 9, 16, 2, 1, 0, 0xffffffffffff3d00ull, expected_96},
    {"cvt22", 16, 16, 1, 2, 1, 0xffffffff3fa00000ull, expected_97},
    {"cvt23", 8, 16, 1, 3, 1, 0xffffffffffff3d00ull, expected_98},
    {"mv_v_f", 9, 16, 2, 4, 0, 0xffffffffffff3d00ull, expected_99},
};
#endif

#define OPV(f, m, a, b, t, d)                                                                      \
    (((uint32_t) (f) << 26) | ((m) << 25) | ((a) << 20) | ((b) << 15) | ((t) << 12) | ((d) << 7) | \
     0x57)
#define EMIT(word) __asm__ volatile(".word %0" ::"i"(word) : "memory")
#define ILLEGAL(word)                                                                              \
    do {                                                                                           \
        vt_trap_clear();                                                                           \
        EMIT(word);                                                                                \
        VT_EQ(vt_trap_count, 1, "reserved form traps");                                            \
        VT_EQ(vt_trap_cause, 2, "illegal-instruction cause");                                      \
        VT_EQ(vt_trap_tval, word, "illegal instruction word");                                     \
    } while (0)
/* Write mstatus as base with FS set to from, run one instruction word and expect FS to end as
 * expect. f12 holds 2.0f for the .vf forms; it is written before FS is set. */
#define FS_CHECK(base, word, from, expect, what)                                                   \
    do {                                                                                           \
        unsigned long after_;                                                                      \
        __asm__ volatile(                                                                          \
            "fmv.w.x f12, %2\n\tcsrw mstatus, %1\n\t.word %3\n\tcsrr %0, mstatus"                  \
            : "=r"(after_)                                                                         \
            : "r"((base) | ((unsigned long) (from) << 13)), "r"(0x40000000ul), "i"(word)           \
            : "f12", "f13", "memory");                                                             \
        VT_EQ((after_ >> 13) & 3, expect, what);                                                   \
    } while (0)

/* A raised flag and an f-register write set FS Dirty; a vector FP instruction that does
 * neither leaves FS as it was, Clean or Initial. v8 holds signaling NaNs. */
static void fs_changes(unsigned long status)
{
    const unsigned long base = (status & ~(VT_MSTATUS_FS | VT_MSTATUS_VS)) | VT_MSTATUS_VS;
    setvl(~0ul, 16);
    splat(12, 0x3f8000003f800000ull);
    VT_CSR_WRITE(fflags, 0);
    FS_CHECK(base, OPV(0x08, 1, 12, 12, 1, 16), 2, 2, "vfsgnj.vv leaves FS Clean");
    FS_CHECK(base, OPV(0x00, 1, 12, 12, 1, 16), 2, 2, "an exact vfadd.vv leaves FS Clean");
    FS_CHECK(base, OPV(0x24, 1, 12, 12, 5, 16), 2, 2, "an exact vfmul.vf leaves FS Clean");
    FS_CHECK(base, OPV(0x10, 1, 0, 12, 5, 16), 2, 2, "vfmv.s.f leaves FS Clean");
    FS_CHECK(base, OPV(0x06, 1, 12, 12, 1, 16), 1, 1, "vfmax.vv leaves FS Initial");
    VT_EQ(VT_CSR_READ(fflags), 0, "these raise no flag");
    FS_CHECK(base, OPV(0x00, 1, 8, 8, 1, 16), 2, 3, "a raised flag dirties FS");
    VT_EQ(VT_CSR_READ(fflags), 16, "the signaling NaN raised invalid");
    FS_CHECK(base, OPV(0x10, 1, 12, 0, 1, 13), 2, 3, "vfmv.f.s dirties FS");
    VT_CSR_WRITE(fflags, 0);
    VT_CSR_WRITE(mstatus, status);
}

/* Set FS immediately before each access. t0 supplies zero through a
 * nonzero rs1 field for the register set and clear controls. */
#define CHECK_CSR_FS(insn, before, expected)                                                       \
    do {                                                                                           \
        unsigned long after;                                                                       \
        __asm__ volatile("li t0, 0\n\tcsrw mstatus, %1\n\t" insn "\n\tcsrr %0, mstatus"            \
                         : "=r"(after)                                                             \
                         : "r"(before)                                                             \
                         : "t0", "memory");                                                        \
        VT_EQ(after & VT_MSTATUS_FS, (expected) & VT_MSTATUS_FS, insn);                            \
    } while (0)

#define CHECK_CSR_FORMS(csr, before)                                                               \
    do {                                                                                           \
        CHECK_CSR_FS("csrrs t0, " #csr ", zero", before, before);                                  \
        CHECK_CSR_FS("csrrc t0, " #csr ", zero", before, before);                                  \
        CHECK_CSR_FS("csrrsi t0, " #csr ", 0", before, before);                                    \
        CHECK_CSR_FS("csrrci t0, " #csr ", 0", before, before);                                    \
        CHECK_CSR_FS("csrrw zero, " #csr ", zero", before, VT_MSTATUS_FS);                         \
        CHECK_CSR_FS("csrrwi zero, " #csr ", 0", before, VT_MSTATUS_FS);                           \
        CHECK_CSR_FS("csrrs t0, " #csr ", t0", before, VT_MSTATUS_FS);                             \
        CHECK_CSR_FS("csrrc t0, " #csr ", t0", before, VT_MSTATUS_FS);                             \
        CHECK_CSR_FS("csrrci t0, " #csr ", 1", before, VT_MSTATUS_FS);                             \
        CHECK_CSR_FS("csrrsi t0, " #csr ", 1", before, VT_MSTATUS_FS);                             \
    } while (0)

static void fp_csr_accesses(unsigned long status)
{
    unsigned long saved_fcsr = VT_CSR_READ(fcsr);
    for (unsigned long fs = 1; fs <= 2; fs++) {
        unsigned long before = (status & ~VT_MSTATUS_FS) | (fs << 13);
        CHECK_CSR_FORMS(fflags, before);
        CHECK_CSR_FORMS(frm, before);
        CHECK_CSR_FORMS(fcsr, before);
    }
    VT_CSR_WRITE(fcsr, saved_fcsr);
    VT_CSR_WRITE(mstatus, status);
}

static void special_cases(void)
{
    uint64_t value;
    VT_CSR_WRITE(frm, 0);
    setvl(~0ul, 24);
    splat(8, 0x3ff000003f800000ull);
    setvl(0, 16);
    __asm__ volatile(".word %1\nfmv.x.d %0,f11"
                     : "=r"(value)
                     : "i"(OPV(0x10, 1, 8, 0, 1, 11))
                     : "f11", "memory");
    VT_EQ(value, 0xffffffff3f800000ull, "FP scalar extract ignores zero vl and boxes single");
    setvl(0, 8);
    __asm__ volatile(".word %1\nfmv.x.d %0,f11"
                     : "=r"(value)
                     : "i"(OPV(0x10, 1, 8, 0, 1, 11))
                     : "f11", "memory");
    VT_EQ(value, 0xffffffffffff0000ull, "FP scalar extract boxes half");
    /* Zvfhmin narrowing at SEW 16: 1.0f becomes 0x3c00, and 65520.0f, the
     * midpoint above the largest finite FP16 value, rounds to infinity. */
    setvl(~0ul, 24);
    splat(8, 0x3f8000003f800000ull);
    splat(9, 0x477ff000477ff000ull);
    setvl(~0ul, 8);
    VT_CSR_WRITE(fflags, 0);
    EMIT(OPV(0x12, 1, 8, 20, 1, 16));
    VT_EQ(VT_CSR_READ(fflags), 5, "FP32 to FP16 overflow is inexact");
    setvl(~0ul, 24);
    for (unsigned word = 0; word < VEC_VLEN / 64; word++)
        VT_EQ(extract(16),
              word < VEC_VLEN / 128 ? 0x3c003c003c003c00ull : 0x7c007c007c007c00ull,
              "vfncvt.f.f.w at SEW 16");
    setvl(~0ul, 16);
    splat(0, 0);
    splat(8, 0x7f8000017f800001ull);
    VT_CSR_WRITE(fflags, 0);
    EMIT(OPV(0, 0, 8, 8, 1, 16));
    VT_EQ(VT_CSR_READ(fflags), 0, "inactive signaling NaNs do not raise flags");
    EMIT(OPV(0, 1, 8, 8, 1, 16));
    VT_EQ(VT_CSR_READ(fflags), 16, "active signaling NaN raises invalid");
    VT_CSR_WRITE(fflags, 0);
    VT_EQ(VT_CSR_READ(fflags), 0, "younger flag clear wins");
    unsigned long status = VT_CSR_READ(mstatus);
    VT_CSR_WRITE(mstatus, (status & ~(VT_MSTATUS_FS | VT_MSTATUS_VS)) | (1ul << 13) | (1ul << 9));
    EMIT(OPV(0, 1, 8, 8, 1, 16));
    VT_EQ((VT_CSR_READ(mstatus) >> 13) & 3, 3, "a raised flag dirties FS from Initial");
    VT_EQ((VT_CSR_READ(mstatus) >> 9) & 3, 3, "vector FP dirties VS");
    fs_changes(status);
    fp_csr_accesses(status);
    VT_CSR_WRITE(mstatus, status & ~VT_MSTATUS_FS);
    ILLEGAL(0x00202073); /* csrrs zero, frm, zero */
    ILLEGAL(0x00305073); /* csrrwi zero, fcsr, 0 */
    VT_EQ(VT_CSR_READ(mstatus) & VT_MSTATUS_FS, 0, "illegal FP CSR accesses preserve FS Off");
    ILLEGAL(OPV(0, 1, 8, 8, 1, 16));
    VT_CSR_WRITE(mstatus, status);
    VT_CSR_WRITE(mstatus, status & ~VT_MSTATUS_VS);
    ILLEGAL(OPV(0, 1, 8, 8, 1, 16));
    VT_CSR_WRITE(mstatus, status);
    VT_CSR_WRITE(frm, 5);
    ILLEGAL(OPV(0, 1, 8, 8, 1, 16));
    VT_CSR_WRITE(frm, 0);
    setvl(~0ul, 0);
    ILLEGAL(OPV(0, 1, 8, 8, 1, 16)); /* FP add has no eight-bit format. */
    setvl(~0ul, 24);
    ILLEGAL(OPV(0x30, 1, 8, 24, 1, 16)); /* Widening beyond ELEN. */
#ifndef VT_SPIKE
    ILLEGAL(OPV(0, 0, 0, 8, 1, 16)); /* Mask and data cannot share v0. */
    ILLEGAL(OPV(3, 0, 8, 0, 1, 16)); /* This includes a reduction seed. */
    ILLEGAL(OPV(0, 0, 8, 0, 1, 16)); /* OPFVV vs1 also reads data. */
    setvl(~0ul, 0x10);
    ILLEGAL(OPV(0x3c, 1, 17, 8, 1, 16));  /* Wide accumulator aliases narrow vs2. */
    ILLEGAL(OPV(0x3d, 1, 8, 17, 1, 16));  /* Wide accumulator aliases narrow vs1. */
    ILLEGAL(OPV(0x3e, 1, 17, 10, 5, 16)); /* The scalar form also reads wide vd. */
#endif
    setvl(~0ul, 0x12);
    ILLEGAL(OPV(0, 1, 8, 24, 1, 17)); /* Misaligned destination group. */
#ifndef VT_SPIKE
    setvl(~0ul, 16);
    VT_CSR_WRITE(vstart, 1);
    ILLEGAL(OPV(0, 1, 8, 24, 1, 16));
    VT_EQ(vt_trap_vstart, 1, "arithmetic nonzero vstart is reserved");
    setvl(0, 16);
    VT_CSR_WRITE(vstart, 1);
    __asm__ volatile(".word %1\nfmv.x.d %0,f11"
                     : "=r"(value)
                     : "i"(OPV(0x10, 1, 8, 0, 1, 11))
                     : "f11", "memory");
    VT_EQ(value, 0xffffffff7f800001ull, "FP scalar extract ignores nonzero vstart");
    VT_EQ(VT_CSR_READ(vstart), 0, "FP scalar extract clears vstart");
#endif
    vt_trap_clear();
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "vector length");
    for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        const struct test_case *t = &cases[k];
        setvl(~0ul, 24);
        for (unsigned r = 0; r < 32; r++)
            splat(r,
                  r == 0 ? 0x5555555555555555ull
                         : 0x3fc000003f800000ull + r * 0x0001000000010000ull);
        setvl(~0ul, t->vt);
        VT_CSR_WRITE(frm, t->rm);
        VT_CSR_WRITE(fflags, 0);
        operation(k, t->scalar);
        VT_EQ(VT_CSR_READ(fflags), t->flags, t->name);
        VT_EQ(VT_CSR_READ(vstart), 0, "vstart clears");
        VT_CSR_WRITE(fflags, 0);
        VT_EQ(VT_CSR_READ(fflags), 0, "ordered flag clear");
        setvl(~0ul, 24);
        for (unsigned r = 0; r < t->regs; r++)
            for (unsigned word = 0; word < VEC_VLEN / 64; word++) {
                uint64_t expected = t->expected[r * (VEC_VLEN / 64) + word];
#ifdef VEC_NEGATIVE_CONTROL
                if (k == 0 && r == 0 && word == 0)
                    expected ^= 1;
#endif
                VT_EQ(extract(t->vd + r), expected, t->name);
            }
        VT_EQ(vt_trap_count, 0, "legal floating point does not trap");
    }
    special_cases();
    return vt_finish("vec_fp_test");
}
