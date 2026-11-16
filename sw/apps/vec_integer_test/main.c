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

/* Integer arithmetic, fixed point, masks and permutations through retirement.
 * Register images come from scalar splats and are observed with scalar moves.
 */
#include "../vec_common/vec_test.h"
#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif
struct test_case {
    const char *name;
    unsigned vt, vd, regs, rm, sat;
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
    register uint64_t a0 __asm__("a0") = scalar;
    switch (k) {
        case 0:
            __asm__ volatile(".word 0x408c0857" ::"r"(a0) : "memory");
            break;
        case 1:
            __asm__ volatile(".word 0x40854857" ::"r"(a0) : "memory");
            break;
        case 2:
            __asm__ volatile(".word 0x4081b857" ::"r"(a0) : "memory");
            break;
        case 3:
            __asm__ volatile(".word 0x468c0857" ::"r"(a0) : "memory");
            break;
        case 4:
            __asm__ volatile(".word 0x44854857" ::"r"(a0) : "memory");
            break;
        case 5:
            __asm__ volatile(".word 0x4681b857" ::"r"(a0) : "memory");
            break;
        case 6:
            __asm__ volatile(".word 0x488c0857" ::"r"(a0) : "memory");
            break;
        case 7:
            __asm__ volatile(".word 0x48854857" ::"r"(a0) : "memory");
            break;
        case 8:
            __asm__ volatile(".word 0x4c8c0857" ::"r"(a0) : "memory");
            break;
        case 9:
            __asm__ volatile(".word 0x4e854857" ::"r"(a0) : "memory");
            break;
        case 10:
            __asm__ volatile(".word 0x808c0857" ::"r"(a0) : "memory");
            break;
        case 11:
            __asm__ volatile(".word 0x82854857" ::"r"(a0) : "memory");
            break;
        case 12:
            __asm__ volatile(".word 0x8081b857" ::"r"(a0) : "memory");
            break;
        case 13:
            __asm__ volatile(".word 0x868c0857" ::"r"(a0) : "memory");
            break;
        case 14:
            __asm__ volatile(".word 0x84854857" ::"r"(a0) : "memory");
            break;
        case 15:
            __asm__ volatile(".word 0x8681b857" ::"r"(a0) : "memory");
            break;
        case 16:
            __asm__ volatile(".word 0x888c0857" ::"r"(a0) : "memory");
            break;
        case 17:
            __asm__ volatile(".word 0x8a854857" ::"r"(a0) : "memory");
            break;
        case 18:
            __asm__ volatile(".word 0x8c8c0857" ::"r"(a0) : "memory");
            break;
        case 19:
            __asm__ volatile(".word 0x8e854857" ::"r"(a0) : "memory");
            break;
        case 20:
            __asm__ volatile(".word 0x9c8c0857" ::"r"(a0) : "memory");
            break;
        case 21:
            __asm__ volatile(".word 0x9e854857" ::"r"(a0) : "memory");
            break;
        case 22:
            __asm__ volatile(".word 0xa88c0857" ::"r"(a0) : "memory");
            break;
        case 23:
            __asm__ volatile(".word 0xaa854857" ::"r"(a0) : "memory");
            break;
        case 24:
            __asm__ volatile(".word 0xa881b857" ::"r"(a0) : "memory");
            break;
        case 25:
            __asm__ volatile(".word 0xae8c0857" ::"r"(a0) : "memory");
            break;
        case 26:
            __asm__ volatile(".word 0xac854857" ::"r"(a0) : "memory");
            break;
        case 27:
            __asm__ volatile(".word 0xae81b857" ::"r"(a0) : "memory");
            break;
        case 28:
            __asm__ volatile(".word 0xb08c0857" ::"r"(a0) : "memory");
            break;
        case 29:
            __asm__ volatile(".word 0xb2854857" ::"r"(a0) : "memory");
            break;
        case 30:
            __asm__ volatile(".word 0xb081b857" ::"r"(a0) : "memory");
            break;
        case 31:
            __asm__ volatile(".word 0xb68c0857" ::"r"(a0) : "memory");
            break;
        case 32:
            __asm__ volatile(".word 0xb4854857" ::"r"(a0) : "memory");
            break;
        case 33:
            __asm__ volatile(".word 0xb681b857" ::"r"(a0) : "memory");
            break;
        case 34:
            __asm__ volatile(".word 0xb88c0857" ::"r"(a0) : "memory");
            break;
        case 35:
            __asm__ volatile(".word 0xba854857" ::"r"(a0) : "memory");
            break;
        case 36:
            __asm__ volatile(".word 0xb881b857" ::"r"(a0) : "memory");
            break;
        case 37:
            __asm__ volatile(".word 0xbe8c0857" ::"r"(a0) : "memory");
            break;
        case 38:
            __asm__ volatile(".word 0xbc854857" ::"r"(a0) : "memory");
            break;
        case 39:
            __asm__ volatile(".word 0xbe81b857" ::"r"(a0) : "memory");
            break;
        case 40:
            __asm__ volatile(".word 0xd48c0857" ::"r"(a0) : "memory");
            break;
        case 41:
            __asm__ volatile(".word 0xd6854857" ::"r"(a0) : "memory");
            break;
        case 42:
            __asm__ volatile(".word 0xd481b857" ::"r"(a0) : "memory");
            break;
        case 43:
            __asm__ volatile(".word 0x328c0857" ::"r"(a0) : "memory");
            break;
        case 44:
            __asm__ volatile(".word 0x30854857" ::"r"(a0) : "memory");
            break;
        case 45:
            __asm__ volatile(".word 0x3281b857" ::"r"(a0) : "memory");
            break;
        case 46:
            __asm__ volatile(".word 0x208c2857" ::"r"(a0) : "memory");
            break;
        case 47:
            __asm__ volatile(".word 0x22856857" ::"r"(a0) : "memory");
            break;
        case 48:
            __asm__ volatile(".word 0x248c2857" ::"r"(a0) : "memory");
            break;
        case 49:
            __asm__ volatile(".word 0x26856857" ::"r"(a0) : "memory");
            break;
        case 50:
            __asm__ volatile(".word 0x288c2857" ::"r"(a0) : "memory");
            break;
        case 51:
            __asm__ volatile(".word 0x2a856857" ::"r"(a0) : "memory");
            break;
        case 52:
            __asm__ volatile(".word 0x2c8c2857" ::"r"(a0) : "memory");
            break;
        case 53:
            __asm__ volatile(".word 0x2e856857" ::"r"(a0) : "memory");
            break;
        case 54:
            __asm__ volatile(".word 0x808c2857" ::"r"(a0) : "memory");
            break;
        case 55:
            __asm__ volatile(".word 0x82856857" ::"r"(a0) : "memory");
            break;
        case 56:
            __asm__ volatile(".word 0x848c2857" ::"r"(a0) : "memory");
            break;
        case 57:
            __asm__ volatile(".word 0x86856857" ::"r"(a0) : "memory");
            break;
        case 58:
            __asm__ volatile(".word 0x888c2857" ::"r"(a0) : "memory");
            break;
        case 59:
            __asm__ volatile(".word 0x8a856857" ::"r"(a0) : "memory");
            break;
        case 60:
            __asm__ volatile(".word 0x8c8c2857" ::"r"(a0) : "memory");
            break;
        case 61:
            __asm__ volatile(".word 0x8e856857" ::"r"(a0) : "memory");
            break;
        case 62:
            __asm__ volatile(".word 0x908c2857" ::"r"(a0) : "memory");
            break;
        case 63:
            __asm__ volatile(".word 0x92856857" ::"r"(a0) : "memory");
            break;
        case 64:
            __asm__ volatile(".word 0x948c2857" ::"r"(a0) : "memory");
            break;
        case 65:
            __asm__ volatile(".word 0x96856857" ::"r"(a0) : "memory");
            break;
        case 66:
            __asm__ volatile(".word 0x988c2857" ::"r"(a0) : "memory");
            break;
        case 67:
            __asm__ volatile(".word 0x9a856857" ::"r"(a0) : "memory");
            break;
        case 68:
            __asm__ volatile(".word 0x9c8c2857" ::"r"(a0) : "memory");
            break;
        case 69:
            __asm__ volatile(".word 0x9e856857" ::"r"(a0) : "memory");
            break;
        case 70:
            __asm__ volatile(".word 0xa48c2857" ::"r"(a0) : "memory");
            break;
        case 71:
            __asm__ volatile(".word 0xa6856857" ::"r"(a0) : "memory");
            break;
        case 72:
            __asm__ volatile(".word 0xac8c2857" ::"r"(a0) : "memory");
            break;
        case 73:
            __asm__ volatile(".word 0xae856857" ::"r"(a0) : "memory");
            break;
        case 74:
            __asm__ volatile(".word 0xb48c2857" ::"r"(a0) : "memory");
            break;
        case 75:
            __asm__ volatile(".word 0xb6856857" ::"r"(a0) : "memory");
            break;
        case 76:
            __asm__ volatile(".word 0xbc8c2857" ::"r"(a0) : "memory");
            break;
        case 77:
            __asm__ volatile(".word 0xbe856857" ::"r"(a0) : "memory");
            break;
        case 78:
            __asm__ volatile(".word 0xc08c2857" ::"r"(a0) : "memory");
            break;
        case 79:
            __asm__ volatile(".word 0xc2856857" ::"r"(a0) : "memory");
            break;
        case 80:
            __asm__ volatile(".word 0xc48c2857" ::"r"(a0) : "memory");
            break;
        case 81:
            __asm__ volatile(".word 0xc6856857" ::"r"(a0) : "memory");
            break;
        case 82:
            __asm__ volatile(".word 0xc88c2857" ::"r"(a0) : "memory");
            break;
        case 83:
            __asm__ volatile(".word 0xca856857" ::"r"(a0) : "memory");
            break;
        case 84:
            __asm__ volatile(".word 0xcc8c2857" ::"r"(a0) : "memory");
            break;
        case 85:
            __asm__ volatile(".word 0xce856857" ::"r"(a0) : "memory");
            break;
        case 86:
            __asm__ volatile(".word 0xd08c2857" ::"r"(a0) : "memory");
            break;
        case 87:
            __asm__ volatile(".word 0xd2856857" ::"r"(a0) : "memory");
            break;
        case 88:
            __asm__ volatile(".word 0xd48c2857" ::"r"(a0) : "memory");
            break;
        case 89:
            __asm__ volatile(".word 0xd6856857" ::"r"(a0) : "memory");
            break;
        case 90:
            __asm__ volatile(".word 0xd88c2857" ::"r"(a0) : "memory");
            break;
        case 91:
            __asm__ volatile(".word 0xda856857" ::"r"(a0) : "memory");
            break;
        case 92:
            __asm__ volatile(".word 0xdc8c2857" ::"r"(a0) : "memory");
            break;
        case 93:
            __asm__ volatile(".word 0xde856857" ::"r"(a0) : "memory");
            break;
        case 94:
            __asm__ volatile(".word 0xe08c2857" ::"r"(a0) : "memory");
            break;
        case 95:
            __asm__ volatile(".word 0xe2856857" ::"r"(a0) : "memory");
            break;
        case 96:
            __asm__ volatile(".word 0xe88c2857" ::"r"(a0) : "memory");
            break;
        case 97:
            __asm__ volatile(".word 0xea856857" ::"r"(a0) : "memory");
            break;
        case 98:
            __asm__ volatile(".word 0xec8c2857" ::"r"(a0) : "memory");
            break;
        case 99:
            __asm__ volatile(".word 0xee856857" ::"r"(a0) : "memory");
            break;
        case 100:
            __asm__ volatile(".word 0xf08c2857" ::"r"(a0) : "memory");
            break;
        case 101:
            __asm__ volatile(".word 0xf2856857" ::"r"(a0) : "memory");
            break;
        case 102:
            __asm__ volatile(".word 0xf48c2857" ::"r"(a0) : "memory");
            break;
        case 103:
            __asm__ volatile(".word 0xf6856857" ::"r"(a0) : "memory");
            break;
        case 104:
            __asm__ volatile(".word 0xfc8c2857" ::"r"(a0) : "memory");
            break;
        case 105:
            __asm__ volatile(".word 0xfe856857" ::"r"(a0) : "memory");
            break;
        case 106:
            __asm__ volatile(".word 0xf8856857" ::"r"(a0) : "memory");
            break;
        case 107:
            __asm__ volatile(".word 0x3a81b857" ::"r"(a0) : "memory");
            break;
        case 108:
            __asm__ volatile(".word 0x38854857" ::"r"(a0) : "memory");
            break;
        case 109:
            __asm__ volatile(".word 0x3e81b857" ::"r"(a0) : "memory");
            break;
        case 110:
            __asm__ volatile(".word 0x3c854857" ::"r"(a0) : "memory");
            break;
        case 111:
            __asm__ volatile(".word 0x3a856857" ::"r"(a0) : "memory");
            break;
        case 112:
            __asm__ volatile(".word 0x3c856857" ::"r"(a0) : "memory");
            break;
        case 113:
            __asm__ volatile(".word 0x3a8c0857" ::"r"(a0) : "memory");
            break;
        case 114:
            __asm__ volatile(".word 0x5e8c2857" ::"r"(a0) : "memory");
            break;
        case 115:
            __asm__ volatile(".word 0x42056857" ::"r"(a0) : "memory");
            break;
        case 116:
            __asm__ volatile(".word 0x9e803857" ::"r"(a0) : "memory");
            break;
        case 117:
            __asm__ volatile(".word 0x9e80b857" ::"r"(a0) : "memory");
            break;
        case 118:
            __asm__ volatile(".word 0x9e81b857" ::"r"(a0) : "memory");
            break;
        case 119:
            __asm__ volatile(".word 0x9e83b857" ::"r"(a0) : "memory");
            break;
        case 120:
            __asm__ volatile(".word 0x48832857" ::"r"(a0) : "memory");
            break;
        case 121:
            __asm__ volatile(".word 0x4a83a857" ::"r"(a0) : "memory");
            break;
        case 122:
            __asm__ volatile(".word 0x48822857" ::"r"(a0) : "memory");
            break;
        case 123:
            __asm__ volatile(".word 0x4a82a857" ::"r"(a0) : "memory");
            break;
        case 124:
            __asm__ volatile(".word 0x48812857" ::"r"(a0) : "memory");
            break;
        case 125:
            __asm__ volatile(".word 0x4a81a857" ::"r"(a0) : "memory");
            break;
        case 126:
            __asm__ volatile(".word 0x5080a857" ::"r"(a0) : "memory");
            break;
        case 127:
            __asm__ volatile(".word 0x52812857" ::"r"(a0) : "memory");
            break;
        case 128:
            __asm__ volatile(".word 0x5081a857" ::"r"(a0) : "memory");
            break;
        case 129:
            __asm__ volatile(".word 0x52882857" ::"r"(a0) : "memory");
            break;
        case 130:
            __asm__ volatile(".word 0x5008a857" ::"r"(a0) : "memory");
            break;
        case 131:
            __asm__ volatile(".word 0x628c2857" ::"r"(a0) : "memory");
            break;
        case 132:
            __asm__ volatile(".word 0x668c2857" ::"r"(a0) : "memory");
            break;
        case 133:
            __asm__ volatile(".word 0x6a8c2857" ::"r"(a0) : "memory");
            break;
        case 134:
            __asm__ volatile(".word 0x6e8c2857" ::"r"(a0) : "memory");
            break;
        case 135:
            __asm__ volatile(".word 0x728c2857" ::"r"(a0) : "memory");
            break;
        case 136:
            __asm__ volatile(".word 0x768c2857" ::"r"(a0) : "memory");
            break;
        case 137:
            __asm__ volatile(".word 0x7a8c2857" ::"r"(a0) : "memory");
            break;
        case 138:
            __asm__ volatile(".word 0x7e8c2857" ::"r"(a0) : "memory");
            break;
        case 139:
            __asm__ volatile(".word 0x0281a2d7" ::"r"(a0) : "memory");
            break;
        case 140:
            __asm__ volatile(".word 0x0481a2d7" ::"r"(a0) : "memory");
            break;
        case 141:
            __asm__ volatile(".word 0x0a81a2d7" ::"r"(a0) : "memory");
            break;
        case 142:
            __asm__ volatile(".word 0x0c81a2d7" ::"r"(a0) : "memory");
            break;
        case 143:
            __asm__ volatile(".word 0x1281a2d7" ::"r"(a0) : "memory");
            break;
        case 144:
            __asm__ volatile(".word 0x1481a2d7" ::"r"(a0) : "memory");
            break;
        case 145:
            __asm__ volatile(".word 0x1a81a2d7" ::"r"(a0) : "memory");
            break;
        case 146:
            __asm__ volatile(".word 0x1c81a2d7" ::"r"(a0) : "memory");
            break;
        case 147:
            __asm__ volatile(".word 0xc28182d7" ::"r"(a0) : "memory");
            break;
        case 148:
            __asm__ volatile(".word 0xc48182d7" ::"r"(a0) : "memory");
            break;
    }
}
#if VEC_VLEN == 128
static const uint64_t expected_0[] = {
    0x2304e6c86b8dafd0ull, 0x2304e6c96b8dafd0ull, 0x2506e8ca6d8fb1d3ull, 0x2506e8cb6d8fb1d3ull};
static const uint64_t expected_1[] = {0x097a6b5b2dbecfdfull, 0x097a6b5c2dbecfdfull};
static const uint64_t expected_2[] = {0x897a6b5fadbecfe3ull, 0x897a6b60adbecfe3ull};
static const uint64_t expected_3[] = {0x91827364b5c6d7ffull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_4[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_5[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_6[] = {
    0xefefeff0efefeff0ull, 0xefefefefefefeff0ull, 0xefefeff0efefefefull, 0xefefefefefefefefull};
static const uint64_t expected_7[] = {0x097a6b5d2dbecfe1ull, 0x097a6b5c2dbecfe1ull};
static const uint64_t expected_8[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_9[] = {0x91827364b5c6d700ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_10[] = {0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull};
static const uint64_t expected_11[] = {0xffffffffffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_12[] = {
    0x91827364b5c6d7e8ull, 0x897a6b5fb5c6d7e8ull, 0x92837465aebfd0e4ull, 0x8a7b6c60aebfd0e4ull};
static const uint64_t expected_13[] = {0x8000000080000000ull, 0x8000000080000000ull};
static const uint64_t expected_14[] = {0x91827364b5c6d7e8ull, 0x097a6b5bb5c6d7e8ull};
static const uint64_t expected_15[] = {
    0x897a6b5fadbecfe3ull, 0x897a6b5fadbecfe3ull, 0x8a7b6c60aebfd0e4ull, 0x8a7b6c60aebfd0e4ull};
static const uint64_t expected_16[] = {0x91827364b5c6d7e8ull, 0x00000000b5c6d7e8ull};
static const uint64_t expected_17[] = {0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull};
static const uint64_t expected_18[] = {
    0x91827364b5c6d7e8ull, 0xefefeff0b5c6d7e8ull, 0x92837465efefeff0ull, 0xefefeff0efefeff0ull};
static const uint64_t expected_19[] = {0x8000000080000000ull, 0x8000000080000000ull};
static const uint64_t expected_20[] = {0x91827364b5c6d7e8ull, 0x5edf434fb5c6d7e8ull};
static const uint64_t expected_21[] = {
    0x897a6b5dadbecfe1ull, 0x897a6b5dadbecfe1ull, 0x8a7b6c5eaebfd0e2ull, 0x8a7b6c5eaebfd0e2ull};
static const uint64_t expected_22[] = {0x91827364b5c6d7e8ull, 0x000897a6b5c6d7e8ull};
static const uint64_t expected_23[] = {0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_24[] = {
    0x91827364b5c6d7e8ull, 0x112f4d6cb5c6d7e8ull, 0x9283746515d7fa1cull, 0x114f6d8c15d7fa1cull};
static const uint64_t expected_25[] = {0xfff897a7ffffadbfull, 0xfff897a7ffffadbfull};
static const uint64_t expected_26[] = {0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull};
static const uint64_t expected_27[] = {
    0xf12f4d6bf5b7d9fcull, 0xf12f4d6bf5b7d9fcull, 0xf14f6d8bf5d7fa1dull, 0xf14f6d8bf5d7fa1dull};
static const uint64_t expected_28[] = {0x91827364b5c6d7e8ull, 0x0008a7b6b5c6d7e8ull};
static const uint64_t expected_29[] = {0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_30[] = {
    0x91827364b5c6d7e8ull, 0xb5d7fa1cb5c6d7e8ull, 0x92837465d5f81a3cull, 0xf6183a5cf6183a5cull};
static const uint64_t expected_31[] = {0xfff897a6ffff897aull, 0xfff8a7b6ffff8a7bull};
static const uint64_t expected_32[] = {0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull};
static const uint64_t expected_33[] = {
    0x95b7d9fc95b7d9fcull, 0xb5d7fa1cb5d7fa1cull, 0xd5f81a3cd5f81a3cull, 0xf6183a5cf6183a5cull};
static const uint64_t expected_34[] = {0x91827364b5c6d7e8ull, 0x0008a7b6b5c6d7e8ull};
static const uint64_t expected_35[] = {0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_36[] = {
    0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull, 0x92837465ffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_37[] = {0xfff897a7ffff897aull, 0xfff8a7b7ffff8a7bull};
static const uint64_t expected_38[] = {0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull};
static const uint64_t expected_39[] = {
    0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull};
static const uint64_t expected_40[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0xa6b5c00000000000ull};
static const uint64_t expected_41[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_42[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0x000000044bd35ae0ull,
                                       0x0000000575fe8708ull,
                                       0x93847566b7c8d9eaull,
                                       0x0000000575fe8708ull,
                                       0x0000000453db62e8ull};
static const uint64_t expected_43[] = {0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_44[] = {0x91827364b5c6d7e8ull, 0x897a6b5cb5c6d7e8ull};
static const uint64_t expected_45[] = {
    0x897a6b5c897a6b5cull, 0x897a6b5c897a6b5cull, 0x897a6b5c897a6b5cull, 0x897a6b5c897a6b5cull};
static const uint64_t expected_46[] = {0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_47[] = {0x84bd35ad96df67efull, 0x84bd35ad96df67efull};
static const uint64_t expected_48[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull};
static const uint64_t expected_49[] = {0x04bd35ae16df67f0ull, 0x04bd35ae16df67f0ull};
static const uint64_t expected_50[] = {0x91827364b5c6d7e8ull, 0xf7f7f7f8b5c6d7e8ull};
static const uint64_t expected_51[] = {
    0x04bd35af16df67f1ull, 0x04bd35af16df67f1ull, 0x053db62f175fe871ull, 0x053db62f175fe871ull};
static const uint64_t expected_52[] = {0x91827364b5c6d7e8ull, 0xf7f7f7f8b5c6d7e8ull};
static const uint64_t expected_53[] = {0x84bd35ae96df67f0ull, 0x84bd35ae96df67f0ull};
static const uint64_t expected_54[] = {
    0x91827364b5c6d7e8ull, 0x00000000b5c6d7e8ull, 0x9283746500000000ull, 0x0000000000000000ull};
static const uint64_t expected_55[] = {0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_56[] = {0x91827364b5c6d7e8ull, 0x00000001b5c6d7e8ull};
static const uint64_t expected_57[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_58[] = {0x91827364b5c6d7e8ull, 0x897a6b5cb5c6d7e8ull};
static const uint64_t expected_59[] = {0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull};
static const uint64_t expected_60[] = {
    0x91827364b5c6d7e8ull, 0xefefeff0b5c6d7e8ull, 0x92837465efefeff0ull, 0xefefeff0efefeff0ull};
static const uint64_t expected_61[] = {0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull};
static const uint64_t expected_62[] = {0x91827364b5c6d7e8ull, 0x5274886fb5c6d7e8ull};
static const uint64_t expected_63[] = {
    0x44bd35ad56df67efull, 0x44bd35ad56df67efull, 0x453db62d575fe86full, 0x453db62d575fe86full};
static const uint64_t expected_64[] = {0x91827364b5c6d7e8ull, 0xacd27ed0b5c6d7e8ull};
static const uint64_t expected_65[] = {0x768594a452413020ull, 0x768594a452413020ull};
static const uint64_t expected_66[] = {
    0x91827364b5c6d7e8ull, 0xb8ea0d03b5c6d7e8ull, 0x92837465c37062bcull, 0xb90e3715c37062bcull};
static const uint64_t expected_67[] = {0xc4bd35aed6df67f0ull, 0xc4bd35aed6df67f0ull};
static const uint64_t expected_68[] = {0x91827364b5c6d7e8ull, 0x2f6fa1a7b5c6d7e8ull};
static const uint64_t expected_69[] = {
    0xc4bd35aed6df67f0ull, 0xc4bd35aed6df67f0ull, 0xc53db62ed75fe870ull, 0xc53db62ed75fe870ull};
static const uint64_t expected_70[] = {0x91827364b5c6d7e8ull, 0x91dc258cb5c6d7e8ull};
static const uint64_t expected_71[] = {0xf7f7f7f8f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_72[] = {
    0x91827364b5c6d7e8ull, 0x8118b12cb5c6d7e8ull, 0x928374656c69bd88ull, 0x874af15c6c69bd88ull};
static const uint64_t expected_73[] = {0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull};
static const uint64_t expected_74[] = {0x91827364b5c6d7e8ull, 0x3e54f234b5c6d7e8ull};
static const uint64_t expected_75[] = {
    0x0808080808080808ull, 0x0808080808080808ull, 0x8808080888080808ull, 0x8808080888080808ull};
static const uint64_t expected_76[] = {0x91827364b5c6d7e8ull, 0xe4aff494b5c6d7e8ull};
static const uint64_t expected_77[] = {0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull};
static const uint64_t expected_78[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0x000000012304e6c8ull,
                                       0x000000016d8fb1d2ull,
                                       0x93847566b7c8d9eaull,
                                       0x000000016d8fb1d2ull,
                                       0x000000012506e8caull};
static const uint64_t expected_79[] = {
    0x000000012dbecfdfull, 0x00000001097a6b5bull, 0x000000012dbecfdfull, 0x00000001097a6b5bull};
static const uint64_t expected_80[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0xffffffff2304e6c8ull};
static const uint64_t expected_81[] = {0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull};
static const uint64_t expected_82[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0xffffffffefefeff0ull};
static const uint64_t expected_83[] = {
    0x000000002dbecfe1ull, 0x00000000097a6b5dull, 0x000000002dbecfe1ull, 0x00000000097a6b5dull};
static const uint64_t expected_84[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x93847566b7c8d9eaull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull};
static const uint64_t expected_85[] = {
    0xffffffff2dbecfe1ull, 0xffffffff097a6b5dull, 0xffffffff2dbecfe1ull, 0xffffffff097a6b5dull};
static const uint64_t expected_86[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x8a7b6c5e484a4c4dull};
static const uint64_t expected_87[] = {0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8c7d6e6030c1d2e2ull,
                                       0x8c7d6e6030c1d2e2ull};
static const uint64_t expected_88[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x8a7b6c5d484a4c4dull};
static const uint64_t expected_89[] = {
    0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull, 0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull};
static const uint64_t expected_90[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5d15355575ull,
                                       0x8b7c6d5df0f0f0f1ull,
                                       0x93847566b7c8d9eaull,
                                       0x8c7d6e5ef1f1f1f2ull,
                                       0x8c7d6e5f16365676ull};
static const uint64_t expected_91[] = {
    0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull, 0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull};
static const uint64_t expected_92[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x8a7b6c5e15355575ull};
static const uint64_t expected_93[] = {0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8c7d6e5f30c1d2e4ull,
                                       0x8c7d6e5f30c1d2e4ull};
static const uint64_t expected_94[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x5274886facd27ed0ull};
static const uint64_t expected_95[] = {
    0x56df67ef52413020ull, 0x44bd35ad768594a4ull, 0x56df67ef52413020ull, 0x44bd35ad768594a4ull};
static const uint64_t expected_96[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0xb8ea0d03acd27ed0ull,
                                       0xc37062bc3d4783d1ull,
                                       0x93847566b7c8d9eaull,
                                       0xc37062bc3d4783d1ull,
                                       0xb90e371587892f99ull};
static const uint64_t expected_97[] = {
    0xd6df67f052413020ull, 0xc4bd35ae768594a4ull, 0xd6df67f052413020ull, 0xc4bd35ae768594a4ull};
static const uint64_t expected_98[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x2f6fa1a7acd27ed0ull};
static const uint64_t expected_99[] = {0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull};
static const uint64_t expected_100[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0xe4f7fcd5639a57b9ull};
static const uint64_t expected_101[] = {
    0xe861db5408080808ull, 0xd63fa9122c4c6c8cull, 0xe962dc5509090909ull, 0xd740aa132d4d6d8dull};
static const uint64_t expected_102[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x92837465b6c7d8e9ull,
                                        0xc1f3160d639a57b9ull,
                                        0xa8350741f5105dbbull,
                                        0x93847566b7c8d9eaull,
                                        0xa9360842f6115ebcull,
                                        0xc318412040530a84ull};
static const uint64_t expected_103[] = {
    0x6861db5508080808ull, 0x563fa9132c4c6c8cull, 0x6962dc5609090909ull, 0x5740aa142d4d6d8dull};
static const uint64_t expected_104[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x5b7d9179639a57b9ull};
static const uint64_t expected_105[] = {0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xeae45dd689090909ull,
                                        0xd8c22b94ad4d6d8dull,
                                        0xebe55ed78a0a0a0aull,
                                        0xd9c32c95ae4e6e8eull};
static const uint64_t expected_106[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x92837465b6c7d8e9ull, 0x5740aa142d4d6d8dull};
static const uint64_t expected_107[] = {0x91827364b5c6d7e8ull, 0xadbecfe0b5c6d7e8ull};
static const uint64_t expected_108[] = {
    0x91827364b5c6d7e8ull, 0xadbecfe0b5c6d7e8ull, 0x92837465897a6b5cull, 0xaebfd0e18a7b6c5dull};
static const uint64_t expected_109[] = {0x00000000897a6b5cull, 0x0000000000000000ull};
static const uint64_t expected_110[] = {0x91827364b5c6d7e8ull, 0x00000000b5c6d7e8ull};
static const uint64_t expected_111[] = {
    0xadbecfe000000001ull, 0xadbecfe0897a6b5cull, 0xaebfd0e1897a6b5cull, 0xaebfd0e18a7b6c5dull};
static const uint64_t expected_112[] = {0x91827364b5c6d7e8ull, 0x00000001b5c6d7e8ull};
static const uint64_t expected_113[] = {0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_114[] = {
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull};
static const uint64_t expected_115[] = {0x918273647fffffffull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_116[] = {0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull};
static const uint64_t expected_117[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull};
static const uint64_t expected_118[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8c7d6e5fb0c1d2e3ull};
static const uint64_t expected_119[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8d7e6f60b1c2d3e4ull,
                                        0x8d7e6f60b1c2d3e4ull,
                                        0x8e7f7061b2c3d4e5ull,
                                        0x8e7f7061b2c3d4e5ull,
                                        0x8f807162b3c4d5e6ull,
                                        0x8f807162b3c4d5e6ull,
                                        0x90817263b4c5d6e7ull,
                                        0x90817263b4c5d6e7ull};
static const uint64_t expected_120[] = {
    0x91827364b5c6d7e8ull, 0x0000897ab5c6d7e8ull, 0x928374650000cfe0ull, 0x0000897a00006b5cull};
static const uint64_t expected_121[] = {0xffffadbeffffcfe0ull, 0xffff897a00006b5cull};
static const uint64_t expected_122[] = {0x91827364b5c6d7e8ull, 0x000000adb5c6d7e8ull};
static const uint64_t expected_123[] = {
    0xffffffcfffffffe0ull, 0xffffffadffffffbeull, 0x0000006b0000005cull, 0xffffff890000007aull};
static const uint64_t expected_124[] = {0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_125[] = {0xffffffffffffffe0ull, 0xffffffffffffffcfull};
static const uint64_t expected_126[] = {0x91827364b5c6d738ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_127[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_128[] = {0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_129[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000200000001ull};
static const uint64_t expected_130[] = {0x91827364b5c6d7e8ull, 0x00000003b5c6d7e8ull};
static const uint64_t expected_131[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_132[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_133[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_134[] = {0x91827364b5c6d7e0ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_135[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_136[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_137[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_138[] = {0x91827364b5c6d7efull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_139[] = {0x86776859172c4153ull, 0x86776859aabbccddull};
static const uint64_t expected_140[] = {0x8677685988384a58ull, 0x86776859aabbccddull};
static const uint64_t expected_141[] = {0x86776859adffefffull, 0x86776859aabbccddull};
static const uint64_t expected_142[] = {0x8677685921c3a187ull, 0x86776859aabbccddull};
static const uint64_t expected_143[] = {0x86776859897a6b5cull, 0x86776859aabbccddull};
static const uint64_t expected_144[] = {0x86776859897a6b5cull, 0x86776859aabbccddull};
static const uint64_t expected_145[] = {0x86776859adbecfe0ull, 0x86776859aabbccddull};
static const uint64_t expected_146[] = {0x86776859a8b9cadbull, 0x86776859aabbccddull};
static const uint64_t expected_147[] = {0x8475665a172c4153ull, 0x86776859aabbccddull};
static const uint64_t expected_148[] = {0x8475665732343637ull, 0x86776859aabbccddull};
static const struct test_case cases[] = {
    {"adc", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_0},
    {"adc", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_1},
    {"adc", 16, 16, 1, 2, 0, 0x0000000000000003ull, expected_2},
    {"madc", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_3},
    {"madc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_4},
    {"madc", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_5},
    {"sbc", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_6},
    {"sbc", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_7},
    {"msbc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_8},
    {"msbc", 17, 16, 1, 1, 0, 0x800000037fffffffull, expected_9},
    {"saddu", 16, 16, 1, 2, 1, 0x800000037fffffffull, expected_10},
    {"saddu", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_11},
    {"saddu", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_12},
    {"sadd", 16, 16, 1, 1, 1, 0x800000037fffffffull, expected_13},
    {"sadd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_14},
    {"sadd", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_15},
    {"ssubu", 16, 16, 1, 0, 1, 0x800000037fffffffull, expected_16},
    {"ssubu", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_17},
    {"ssub", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_18},
    {"ssub", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_19},
    {"smul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_20},
    {"smul", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_21},
    {"ssrl", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_22},
    {"ssrl", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_23},
    {"ssrl", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_24},
    {"ssra", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_25},
    {"ssra", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_26},
    {"ssra", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_27},
    {"nsrl", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_28},
    {"nsrl", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_29},
    {"nsrl", 17, 16, 2, 2, 0, 0x0000000000000003ull, expected_30},
    {"nsra", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_31},
    {"nsra", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_32},
    {"nsra", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_33},
    {"nclipu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_34},
    {"nclipu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_35},
    {"nclipu", 17, 16, 2, 0, 1, 0x0000000000000003ull, expected_36},
    {"nclip", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_37},
    {"nclip", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_38},
    {"nclip", 17, 16, 2, 3, 1, 0x0000000000000003ull, expected_39},
    {"wsll", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_40},
    {"wsll", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_41},
    {"wsll", 17, 16, 4, 2, 0, 0x0000000000000003ull, expected_42},
    {"rgather", 16, 16, 1, 3, 0, 0x0000000000000001ull, expected_43},
    {"rgather", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_44},
    {"rgather", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_45},
    {"aaddu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_46},
    {"aaddu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_47},
    {"aadd", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_48},
    {"aadd", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_49},
    {"asubu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_50},
    {"asubu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_51},
    {"asub", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_52},
    {"asub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_53},
    {"divu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_54},
    {"divu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_55},
    {"div", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_56},
    {"div", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_57},
    {"remu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_58},
    {"remu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_59},
    {"rem", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_60},
    {"rem", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_61},
    {"mulhu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_62},
    {"mulhu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_63},
    {"mul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_64},
    {"mul", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_65},
    {"mulhsu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_66},
    {"mulhsu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_67},
    {"mulh", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_68},
    {"mulh", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_69},
    {"madd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_70},
    {"madd", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_71},
    {"nmsub", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_72},
    {"nmsub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_73},
    {"macc", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_74},
    {"macc", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_75},
    {"nmsac", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_76},
    {"nmsac", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_77},
    {"waddu", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_78},
    {"waddu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_79},
    {"wadd", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_80},
    {"wadd", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_81},
    {"wsubu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_82},
    {"wsubu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_83},
    {"wsub", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_84},
    {"wsub", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_85},
    {"waddu_w", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_86},
    {"waddu_w", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_87},
    {"wadd_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_88},
    {"wadd_w", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_89},
    {"wsubu_w", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_90},
    {"wsubu_w", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_91},
    {"wsub_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_92},
    {"wsub_w", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_93},
    {"wmulu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_94},
    {"wmulu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_95},
    {"wmulsu", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_96},
    {"wmulsu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_97},
    {"wmul", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_98},
    {"wmul", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_99},
    {"wmaccu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_100},
    {"wmaccu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_101},
    {"wmacc", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_102},
    {"wmacc", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_103},
    {"wmaccsu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_104},
    {"wmaccsu", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_105},
    {"wmaccus", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_106},
    {"slideup", 16, 16, 1, 3, 0, 0x0000000000000003ull, expected_107},
    {"slideup", 17, 16, 2, 0, 0, 0x0000000000000001ull, expected_108},
    {"slidedown", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_109},
    {"slidedown", 16, 16, 1, 2, 0, 0x0000000000000001ull, expected_110},
    {"slide1up", 17, 16, 2, 3, 0, 0x0000000000000001ull, expected_111},
    {"slide1down", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_112},
    {"rgatherei16", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_113},
    {"compress", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_114},
    {"mv_s_x", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_115},
    {"mv1r", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_116},
    {"mv2r", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_117},
    {"mv4r", 16, 16, 4, 2, 0, 0x800000037fffffffull, expected_118},
    {"mv8r", 16, 16, 8, 3, 0, 0x800000037fffffffull, expected_119},
    {"zext2", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_120},
    {"sext2", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_121},
    {"zext4", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_122},
    {"sext4", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_123},
    {"zext8", 24, 16, 1, 0, 0, 0x800000037fffffffull, expected_124},
    {"sext8", 24, 16, 1, 1, 0, 0x800000037fffffffull, expected_125},
    {"msbf", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_126},
    {"msof", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_127},
    {"msif", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_128},
    {"iota", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_129},
    {"id", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_130},
    {"mandn", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_131},
    {"mand", 17, 16, 1, 0, 0, 0x800000037fffffffull, expected_132},
    {"mor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_133},
    {"mxor", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_134},
    {"morn", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_135},
    {"mnand", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_136},
    {"mnor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_137},
    {"mxnor", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_138},
    {"redsum", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_139},
    {"redand", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_140},
    {"redor", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_141},
    {"redxor", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_142},
    {"redminu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_143},
    {"redmin", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_144},
    {"redmaxu", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_145},
    {"redmax", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_146},
    {"wredsumu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_147},
    {"wredsum", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_148},
};
#endif
#if VEC_VLEN == 256
static const uint64_t expected_0[] = {0x2304e6c86b8dafd0ull,
                                      0x2304e6c96b8dafd0ull,
                                      0x2304e6c86b8dafd1ull,
                                      0x2304e6c96b8dafd1ull,
                                      0x2506e8cb6d8fb1d3ull,
                                      0x2506e8ca6d8fb1d3ull,
                                      0x2506e8ca6d8fb1d2ull,
                                      0x2506e8cb6d8fb1d3ull};
static const uint64_t expected_1[] = {
    0x097a6b5b2dbecfdfull, 0x097a6b5c2dbecfdfull, 0x097a6b5b2dbecfe0ull, 0x097a6b5c2dbecfe0ull};
static const uint64_t expected_2[] = {
    0x897a6b5fadbecfe3ull, 0x897a6b60adbecfe3ull, 0x897a6b5fadbecfe4ull, 0x897a6b60adbecfe4ull};
static const uint64_t expected_3[] = {
    0x91827364b5c6ffffull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_4[] = {
    0x91827364b5c6d7ffull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_5[] = {
    0x91827364b5c6d700ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_6[] = {0xefefeff0efefeff0ull,
                                      0xefefefefefefeff0ull,
                                      0xefefeff0efefefefull,
                                      0xefefefefefefefefull,
                                      0xefefefefefefefefull,
                                      0xefefeff0efefefefull,
                                      0xefefeff0efefeff0ull,
                                      0xefefefefefefefefull};
static const uint64_t expected_7[] = {
    0x097a6b5d2dbecfe1ull, 0x097a6b5c2dbecfe1ull, 0x097a6b5d2dbecfe0ull, 0x097a6b5c2dbecfe0ull};
static const uint64_t expected_8[] = {
    0x91827364b5c6d7ffull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_9[] = {
    0x91827364b5c60000ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_10[] = {
    0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull, 0x91827364ffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_11[] = {
    0xffffffffffffffffull, 0xffffffffffffffffull, 0xffffffffffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_12[] = {0x91827364b5c6d7e8ull,
                                       0x897a6b5fb5c6d7e8ull,
                                       0x91827364adbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x92837465aebfd0e4ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c60aebfd0e4ull};
static const uint64_t expected_13[] = {
    0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull};
static const uint64_t expected_14[] = {
    0x91827364b5c6d7e8ull, 0x097a6b5bb5c6d7e8ull, 0x918273642dbecfdfull, 0x097a6b5b2dbecfdfull};
static const uint64_t expected_15[] = {0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull};
static const uint64_t expected_16[] = {
    0x91827364b5c6d7e8ull, 0x00000000b5c6d7e8ull, 0x9182736400000000ull, 0x0000000000000000ull};
static const uint64_t expected_17[] = {
    0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull};
static const uint64_t expected_18[] = {0x91827364b5c6d7e8ull,
                                       0xefefeff0b5c6d7e8ull,
                                       0x91827364efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0x92837465efefeff0ull,
                                       0x92837465b6c7d8e9ull,
                                       0xefefeff0efefeff0ull};
static const uint64_t expected_19[] = {
    0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull, 0x8000000080000000ull};
static const uint64_t expected_20[] = {
    0x91827364b5c6d7e8ull, 0x5edf434fb5c6d7e8ull, 0x918273642a892e60ull, 0x5edf434f2a892e60ull};
static const uint64_t expected_21[] = {0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull};
static const uint64_t expected_22[] = {
    0x91827364b5c6d7e8ull, 0x000897a6b5c6d7e8ull, 0x918273640000adbeull, 0x000897a60000adbeull};
static const uint64_t expected_23[] = {
    0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_24[] = {0x91827364b5c6d7e8ull,
                                       0x112f4d6cb5c6d7e8ull,
                                       0x9182736415b7d9fcull,
                                       0x112f4d6c15b7d9fcull,
                                       0x114f6d8c15d7fa1cull,
                                       0x9283746515d7fa1cull,
                                       0x92837465b6c7d8e9ull,
                                       0x114f6d8c15d7fa1cull};
static const uint64_t expected_25[] = {
    0xfff897a7ffffadbfull, 0xfff897a7ffffadbfull, 0xfff897a7ffffadbfull, 0xfff897a7ffffadbfull};
static const uint64_t expected_26[] = {
    0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull, 0x91827364ffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_27[] = {0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull};
static const uint64_t expected_28[] = {
    0x91827364b5c6d7e8ull, 0x000897a6b5c6d7e8ull, 0x9182736400008a7bull, 0x0008a7b600008a7bull};
static const uint64_t expected_29[] = {
    0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_30[] = {0x91827364b5c6d7e8ull,
                                       0x95b7d9fcb5c6d7e8ull,
                                       0x91827364b5d7fa1cull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0x92837465d5f81a3cull,
                                       0x92837465b6c7d8e9ull,
                                       0xf6183a5cf6183a5cull};
static const uint64_t expected_31[] = {
    0xfff897a6ffff897aull, 0xfff897a6ffff897aull, 0xfff8a7b6ffff8a7bull, 0xfff8a7b6ffff8a7bull};
static const uint64_t expected_32[] = {
    0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull, 0x91827364ffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_33[] = {0x95b7d9fc95b7d9fcull,
                                       0x95b7d9fc95b7d9fcull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xf6183a5cf6183a5cull,
                                       0xf6183a5cf6183a5cull};
static const uint64_t expected_34[] = {
    0x91827364b5c6d7e8ull, 0x000897a6b5c6d7e8ull, 0x9182736400008a7bull, 0x0008a7b600008a7bull};
static const uint64_t expected_35[] = {
    0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_36[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x92837465ffffffffull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffffffffffffull};
static const uint64_t expected_37[] = {
    0xfff897a7ffff897aull, 0xfff897a7ffff897aull, 0xfff8a7b7ffff8a7bull, 0xfff8a7b7ffff8a7bull};
static const uint64_t expected_38[] = {
    0x91827364b5c6d7e8ull, 0xffffffffb5c6d7e8ull, 0x91827364ffffffffull, 0xffffffffffffffffull};
static const uint64_t expected_39[] = {0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull};
static const uint64_t expected_40[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xa6b5c00000000000ull,
                                       0xcfe0000000000000ull,
                                       0x92837465b6c7d8e9ull,
                                       0xcfe0000000000000ull,
                                       0xa6b5c00000000000ull};
static const uint64_t expected_41[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_42[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x000000044bd35ae0ull,
                                       0x000000056df67f00ull,
                                       0x92837465b6c7d8e9ull,
                                       0x000000056df67f00ull,
                                       0x000000044bd35ae0ull,
                                       0x0000000575fe8708ull,
                                       0x0000000453db62e8ull,
                                       0x0000000575fe8708ull,
                                       0x93847566b7c8d9eaull,
                                       0x94857667b8c9daebull,
                                       0x94857667b8c9daebull,
                                       0x0000000575fe8708ull,
                                       0x0000000453db62e8ull};
static const uint64_t expected_43[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_44[] = {
    0x91827364b5c6d7e8ull, 0x897a6b5cb5c6d7e8ull, 0x91827364897a6b5cull, 0x897a6b5c897a6b5cull};
static const uint64_t expected_45[] = {0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull};
static const uint64_t expected_46[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_47[] = {
    0x84bd35ad96df67efull, 0x84bd35ad96df67efull, 0x84bd35ad96df67efull, 0x84bd35ad96df67efull};
static const uint64_t expected_48[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull};
static const uint64_t expected_49[] = {
    0x04bd35ae16df67f0ull, 0x04bd35ae16df67f0ull, 0x04bd35ae16df67f0ull, 0x04bd35ae16df67f0ull};
static const uint64_t expected_50[] = {
    0x91827364b5c6d7e8ull, 0xf7f7f7f8b5c6d7e8ull, 0x91827364f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_51[] = {0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull};
static const uint64_t expected_52[] = {
    0x91827364b5c6d7e8ull, 0xf7f7f7f8b5c6d7e8ull, 0x91827364f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_53[] = {
    0x84bd35ae96df67f0ull, 0x84bd35ae96df67f0ull, 0x84bd35ae96df67f0ull, 0x84bd35ae96df67f0ull};
static const uint64_t expected_54[] = {0x91827364b5c6d7e8ull,
                                       0x00000000b5c6d7e8ull,
                                       0x9182736400000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x9283746500000000ull,
                                       0x92837465b6c7d8e9ull,
                                       0x0000000000000000ull};
static const uint64_t expected_55[] = {
    0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull, 0x0000000100000001ull};
static const uint64_t expected_56[] = {
    0x91827364b5c6d7e8ull, 0x00000001b5c6d7e8ull, 0x9182736400000001ull, 0x0000000100000001ull};
static const uint64_t expected_57[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_58[] = {
    0x91827364b5c6d7e8ull, 0x897a6b5cb5c6d7e8ull, 0x91827364adbecfe0ull, 0x897a6b5cadbecfe0ull};
static const uint64_t expected_59[] = {
    0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull, 0x097a6b5d2dbecfe1ull};
static const uint64_t expected_60[] = {0x91827364b5c6d7e8ull,
                                       0xefefeff0b5c6d7e8ull,
                                       0x91827364efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0x92837465efefeff0ull,
                                       0x92837465b6c7d8e9ull,
                                       0xefefeff0efefeff0ull};
static const uint64_t expected_61[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull};
static const uint64_t expected_62[] = {
    0x91827364b5c6d7e8ull, 0x5274886fb5c6d7e8ull, 0x9182736480d246ffull, 0x5274886f80d246ffull};
static const uint64_t expected_63[] = {0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full};
static const uint64_t expected_64[] = {
    0x91827364b5c6d7e8ull, 0xacd27ed0b5c6d7e8ull, 0x91827364c0370200ull, 0xacd27ed0c0370200ull};
static const uint64_t expected_65[] = {
    0x768594a452413020ull, 0x768594a452413020ull, 0x768594a452413020ull, 0x768594a452413020ull};
static const uint64_t expected_66[] = {0x91827364b5c6d7e8ull,
                                       0xb8ea0d03b5c6d7e8ull,
                                       0x91827364c303670full,
                                       0xb8ea0d03c303670full,
                                       0xb90e3715c37062bcull,
                                       0x92837465c37062bcull,
                                       0x92837465b6c7d8e9ull,
                                       0xb90e3715c37062bcull};
static const uint64_t expected_67[] = {
    0xc4bd35aed6df67f0ull, 0xc4bd35aed6df67f0ull, 0xc4bd35aed6df67f0ull, 0xc4bd35aed6df67f0ull};
static const uint64_t expected_68[] = {
    0x91827364b5c6d7e8ull, 0x2f6fa1a7b5c6d7e8ull, 0x918273641544972full, 0x2f6fa1a71544972full};
static const uint64_t expected_69[] = {0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull};
static const uint64_t expected_70[] = {
    0x91827364b5c6d7e8ull, 0x91dc258cb5c6d7e8ull, 0x9182736452ec5160ull, 0x91dc258c52ec5160ull};
static const uint64_t expected_71[] = {
    0xf7f7f7f8f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull, 0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_72[] = {0x91827364b5c6d7e8ull,
                                       0x8118b12cb5c6d7e8ull,
                                       0x9182736408914e60ull,
                                       0x8118b12c08914e60ull,
                                       0x874af15c6c69bd88ull,
                                       0x928374656c69bd88ull,
                                       0x92837465b6c7d8e9ull,
                                       0x874af15c6c69bd88ull};
static const uint64_t expected_73[] = {
    0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull};
static const uint64_t expected_74[] = {
    0x91827364b5c6d7e8ull, 0x3e54f234b5c6d7e8ull, 0x9182736475fdd9e8ull, 0x3e54f23475fdd9e8ull};
static const uint64_t expected_75[] = {0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull};
static const uint64_t expected_76[] = {
    0x91827364b5c6d7e8ull, 0xe4aff494b5c6d7e8ull, 0x91827364f58fd5e8ull, 0xe4aff494f58fd5e8ull};
static const uint64_t expected_77[] = {
    0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull, 0x1afcdec06385a7c8ull};
static const uint64_t expected_78[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x000000012304e6c8ull,
                                       0x000000016b8dafd0ull,
                                       0x92837465b6c7d8e9ull,
                                       0x000000016b8dafd0ull,
                                       0x000000012304e6c8ull,
                                       0x000000016d8fb1d2ull,
                                       0x000000012506e8caull,
                                       0x000000016d8fb1d2ull,
                                       0x93847566b7c8d9eaull,
                                       0x94857667b8c9daebull,
                                       0x94857667b8c9daebull,
                                       0x000000016d8fb1d2ull,
                                       0x000000012506e8caull};
static const uint64_t expected_79[] = {0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull};
static const uint64_t expected_80[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffff2304e6c8ull,
                                       0xffffffff6b8dafd0ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffff6b8dafd0ull,
                                       0xffffffff2304e6c8ull};
static const uint64_t expected_81[] = {0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002dbecfdfull,
                                       0x00000000097a6b5bull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull,
                                       0x000000002ebfd0e0ull,
                                       0x000000000a7b6c5cull};
static const uint64_t expected_82[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull};
static const uint64_t expected_83[] = {0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull};
static const uint64_t expected_84[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x93847566b7c8d9eaull,
                                       0x94857667b8c9daebull,
                                       0x94857667b8c9daebull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull};
static const uint64_t expected_85[] = {0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull};
static const uint64_t expected_86[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5d47494b4cull,
                                       0x8a7b6c5e6c8eb0d1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5e6c8eb0d1ull,
                                       0x8a7b6c5e484a4c4dull};
static const uint64_t expected_87[] = {0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8b7c6d5f2fc0d1e1ull,
                                       0x8c7d6e6030c1d2e2ull,
                                       0x8c7d6e6030c1d2e2ull,
                                       0x8c7d6e6030c1d2e2ull,
                                       0x8c7d6e6030c1d2e2ull};
static const uint64_t expected_88[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5c47494b4cull,
                                       0x8a7b6c5d6c8eb0d1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5d6c8eb0d1ull,
                                       0x8a7b6c5d484a4c4dull};
static const uint64_t expected_89[] = {0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull};
static const uint64_t expected_90[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5c14345474ull,
                                       0x8a7b6c5cf0f0f0f1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5cf0f0f0f1ull,
                                       0x8a7b6c5d15355575ull,
                                       0x8b7c6d5df0f0f0f1ull,
                                       0x8b7c6d5e15355575ull,
                                       0x8b7c6d5df0f0f0f1ull,
                                       0x93847566b7c8d9eaull,
                                       0x94857667b8c9daebull,
                                       0x94857667b8c9daebull,
                                       0x8c7d6e5ef1f1f1f2ull,
                                       0x8c7d6e5f16365676ull};
static const uint64_t expected_91[] = {0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull};
static const uint64_t expected_92[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5d14345474ull,
                                       0x8a7b6c5df0f0f0f1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5df0f0f0f1ull,
                                       0x8a7b6c5e15355575ull};
static const uint64_t expected_93[] = {0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8b7c6d5e2fc0d1e3ull,
                                       0x8c7d6e5f30c1d2e4ull,
                                       0x8c7d6e5f30c1d2e4ull,
                                       0x8c7d6e5f30c1d2e4ull,
                                       0x8c7d6e5f30c1d2e4ull};
static const uint64_t expected_94[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x5274886facd27ed0ull,
                                       0x80d246ffc0370200ull,
                                       0x92837465b6c7d8e9ull,
                                       0x80d246ffc0370200ull,
                                       0x5274886facd27ed0ull};
static const uint64_t expected_95[] = {0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull};
static const uint64_t expected_96[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xb8ea0d03acd27ed0ull,
                                       0xc303670fc0370200ull,
                                       0x92837465b6c7d8e9ull,
                                       0xc303670fc0370200ull,
                                       0xb8ea0d03acd27ed0ull,
                                       0xc37062bc3d4783d1ull,
                                       0xb90e371587892f99ull,
                                       0xc37062bc3d4783d1ull,
                                       0x93847566b7c8d9eaull,
                                       0x94857667b8c9daebull,
                                       0x94857667b8c9daebull,
                                       0xc37062bc3d4783d1ull,
                                       0xb90e371587892f99ull};
static const uint64_t expected_97[] = {0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull};
static const uint64_t expected_98[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x2f6fa1a7acd27ed0ull,
                                       0x1544972fc0370200ull,
                                       0x92837465b6c7d8e9ull,
                                       0x1544972fc0370200ull,
                                       0x2f6fa1a7acd27ed0ull};
static const uint64_t expected_99[] = {0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull,
                                       0xd75fe870d1402f1full,
                                       0xc53db62ef58493a3ull};
static const uint64_t expected_100[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0xe3f6fbd4629956b8ull,
                                        0x1355bb6576fedae9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x1355bb6576fedae9ull,
                                        0xe4f7fcd5639a57b9ull};
static const uint64_t expected_101[] = {0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull};
static const uint64_t expected_102[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0xc0f2150c629956b8ull,
                                        0xa7c80b9576fedae9ull,
                                        0x92837465b6c7d8e9ull,
                                        0xa7c80b9576fedae9ull,
                                        0xc1f3160d639a57b9ull,
                                        0xa8350741f5105dbbull,
                                        0xc217401f3f520983ull,
                                        0xa8350741f5105dbbull,
                                        0x93847566b7c8d9eaull,
                                        0x94857667b8c9daebull,
                                        0x94857667b8c9daebull,
                                        0xa9360842f6115ebcull,
                                        0xc318412040530a84ull};
static const uint64_t expected_103[] = {0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull};
static const uint64_t expected_104[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x5a7c9078629956b8ull,
                                        0x6596eb8576fedae9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x6596eb8576fedae9ull,
                                        0x5b7d9179639a57b9ull};
static const uint64_t expected_105[] = {0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xeae45dd689090909ull,
                                        0xd8c22b94ad4d6d8dull,
                                        0xeae45dd689090909ull,
                                        0xd8c22b94ad4d6d8dull,
                                        0xebe55ed78a0a0a0aull,
                                        0xd9c32c95ae4e6e8eull,
                                        0xebe55ed78a0a0a0aull,
                                        0xd9c32c95ae4e6e8eull};
static const uint64_t expected_106[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6962dc5609090909ull,
                                        0x92837465b6c7d8e9ull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull};
static const uint64_t expected_107[] = {
    0x91827364b5c6d7e8ull, 0xadbecfe0b5c6d7e8ull, 0xadbecfe0897a6b5cull, 0xadbecfe0897a6b5cull};
static const uint64_t expected_108[] = {0x91827364b5c6d7e8ull,
                                        0xadbecfe0b5c6d7e8ull,
                                        0x91827364897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xaebfd0e1897a6b5cull,
                                        0x928374658a7b6c5dull,
                                        0x92837465b6c7d8e9ull,
                                        0xaebfd0e18a7b6c5dull};
static const uint64_t expected_109[] = {
    0xadbecfe0897a6b5cull, 0xadbecfe0897a6b5cull, 0x00000000897a6b5cull, 0x0000000000000000ull};
static const uint64_t expected_110[] = {
    0x91827364b5c6d7e8ull, 0xadbecfe0b5c6d7e8ull, 0x91827364897a6b5cull, 0x00000000897a6b5cull};
static const uint64_t expected_111[] = {0xadbecfe000000001ull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xaebfd0e1897a6b5cull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull};
static const uint64_t expected_112[] = {
    0x91827364b5c6d7e8ull, 0xadbecfe0b5c6d7e8ull, 0x91827364897a6b5cull, 0x00000001897a6b5cull};
static const uint64_t expected_113[] = {
    0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull};
static const uint64_t expected_114[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0xaebfd0e1aebfd0e1ull,
                                        0x928374658a7b6c5dull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull};
static const uint64_t expected_115[] = {
    0x918273647fffffffull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_116[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull};
static const uint64_t expected_117[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull};
static const uint64_t expected_118[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8b7c6d5eafc0d1e2ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8c7d6e5fb0c1d2e3ull,
                                        0x8c7d6e5fb0c1d2e3ull};
static const uint64_t expected_119[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull,
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull,
    0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull,
    0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull,
    0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull,
    0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull,
    0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull,
    0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull};
static const uint64_t expected_120[] = {0x91827364b5c6d7e8ull,
                                        0x0000897ab5c6d7e8ull,
                                        0x918273640000cfe0ull,
                                        0x0000897a00006b5cull,
                                        0x0000adbe0000cfe0ull,
                                        0x9283746500006b5cull,
                                        0x92837465b6c7d8e9ull,
                                        0x0000897a00006b5cull};
static const uint64_t expected_121[] = {
    0xffffadbeffffcfe0ull, 0xffff897a00006b5cull, 0xffffadbeffffcfe0ull, 0xffff897a00006b5cull};
static const uint64_t expected_122[] = {
    0x91827364b5c6d7e8ull, 0x000000adb5c6d7e8ull, 0x918273640000005cull, 0x000000890000007aull};
static const uint64_t expected_123[] = {0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull,
                                        0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull};
static const uint64_t expected_124[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x00000000000000adull};
static const uint64_t expected_125[] = {
    0xffffffffffffffe0ull, 0xffffffffffffffcfull, 0xffffffffffffffbeull, 0xffffffffffffffadull};
static const uint64_t expected_126[] = {
    0x91827364b5c61038ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_127[] = {
    0x91827364b5c6d720ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_128[] = {
    0x91827364b5c6d778ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_129[] = {0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000200000001ull,
                                        0x0000000400000003ull,
                                        0x0000000600000005ull,
                                        0x0000000700000007ull,
                                        0x0000000800000007ull};
static const uint64_t expected_130[] = {
    0x91827364b5c6d7e8ull, 0x00000003b5c6d7e8ull, 0x9182736400000004ull, 0x0000000700000006ull};
static const uint64_t expected_131[] = {
    0x91827364b5c6d700ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_132[] = {
    0x91827364b5c6cfe0ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_133[] = {
    0x91827364b5c6d7f0ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_134[] = {
    0x91827364b5c6d710ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_135[] = {
    0x91827364b5c6efefull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_136[] = {
    0x91827364b5c6d71full, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_137[] = {
    0x91827364b5c6d70full, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_138[] = {
    0x91827364b5c6efefull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull};
static const uint64_t expected_139[] = {
    0x86776859859eb7cbull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_140[] = {
    0x8677685988384a40ull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_141[] = {
    0x86776859adffefffull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_142[] = {
    0x86776859a8b9cadbull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_143[] = {
    0x86776859897a6b5cull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_144[] = {
    0x86776859897a6b5cull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_145[] = {
    0x86776859adbecfe0ull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_146[] = {
    0x86776859adbecfe0ull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_147[] = {
    0x8475665c859eb7cbull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const uint64_t expected_148[] = {
    0x84756656172c4153ull, 0x86776859aabbccddull, 0x86776859aabbccddull, 0x86776859aabbccddull};
static const struct test_case cases[] = {
    {"adc", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_0},
    {"adc", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_1},
    {"adc", 16, 16, 1, 2, 0, 0x0000000000000003ull, expected_2},
    {"madc", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_3},
    {"madc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_4},
    {"madc", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_5},
    {"sbc", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_6},
    {"sbc", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_7},
    {"msbc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_8},
    {"msbc", 17, 16, 1, 1, 0, 0x800000037fffffffull, expected_9},
    {"saddu", 16, 16, 1, 2, 1, 0x800000037fffffffull, expected_10},
    {"saddu", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_11},
    {"saddu", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_12},
    {"sadd", 16, 16, 1, 1, 1, 0x800000037fffffffull, expected_13},
    {"sadd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_14},
    {"sadd", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_15},
    {"ssubu", 16, 16, 1, 0, 1, 0x800000037fffffffull, expected_16},
    {"ssubu", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_17},
    {"ssub", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_18},
    {"ssub", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_19},
    {"smul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_20},
    {"smul", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_21},
    {"ssrl", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_22},
    {"ssrl", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_23},
    {"ssrl", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_24},
    {"ssra", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_25},
    {"ssra", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_26},
    {"ssra", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_27},
    {"nsrl", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_28},
    {"nsrl", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_29},
    {"nsrl", 17, 16, 2, 2, 0, 0x0000000000000003ull, expected_30},
    {"nsra", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_31},
    {"nsra", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_32},
    {"nsra", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_33},
    {"nclipu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_34},
    {"nclipu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_35},
    {"nclipu", 17, 16, 2, 0, 1, 0x0000000000000003ull, expected_36},
    {"nclip", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_37},
    {"nclip", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_38},
    {"nclip", 17, 16, 2, 3, 1, 0x0000000000000003ull, expected_39},
    {"wsll", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_40},
    {"wsll", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_41},
    {"wsll", 17, 16, 4, 2, 0, 0x0000000000000003ull, expected_42},
    {"rgather", 16, 16, 1, 3, 0, 0x0000000000000001ull, expected_43},
    {"rgather", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_44},
    {"rgather", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_45},
    {"aaddu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_46},
    {"aaddu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_47},
    {"aadd", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_48},
    {"aadd", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_49},
    {"asubu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_50},
    {"asubu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_51},
    {"asub", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_52},
    {"asub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_53},
    {"divu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_54},
    {"divu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_55},
    {"div", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_56},
    {"div", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_57},
    {"remu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_58},
    {"remu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_59},
    {"rem", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_60},
    {"rem", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_61},
    {"mulhu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_62},
    {"mulhu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_63},
    {"mul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_64},
    {"mul", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_65},
    {"mulhsu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_66},
    {"mulhsu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_67},
    {"mulh", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_68},
    {"mulh", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_69},
    {"madd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_70},
    {"madd", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_71},
    {"nmsub", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_72},
    {"nmsub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_73},
    {"macc", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_74},
    {"macc", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_75},
    {"nmsac", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_76},
    {"nmsac", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_77},
    {"waddu", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_78},
    {"waddu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_79},
    {"wadd", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_80},
    {"wadd", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_81},
    {"wsubu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_82},
    {"wsubu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_83},
    {"wsub", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_84},
    {"wsub", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_85},
    {"waddu_w", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_86},
    {"waddu_w", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_87},
    {"wadd_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_88},
    {"wadd_w", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_89},
    {"wsubu_w", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_90},
    {"wsubu_w", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_91},
    {"wsub_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_92},
    {"wsub_w", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_93},
    {"wmulu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_94},
    {"wmulu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_95},
    {"wmulsu", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_96},
    {"wmulsu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_97},
    {"wmul", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_98},
    {"wmul", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_99},
    {"wmaccu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_100},
    {"wmaccu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_101},
    {"wmacc", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_102},
    {"wmacc", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_103},
    {"wmaccsu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_104},
    {"wmaccsu", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_105},
    {"wmaccus", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_106},
    {"slideup", 16, 16, 1, 3, 0, 0x0000000000000003ull, expected_107},
    {"slideup", 17, 16, 2, 0, 0, 0x0000000000000001ull, expected_108},
    {"slidedown", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_109},
    {"slidedown", 16, 16, 1, 2, 0, 0x0000000000000001ull, expected_110},
    {"slide1up", 17, 16, 2, 3, 0, 0x0000000000000001ull, expected_111},
    {"slide1down", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_112},
    {"rgatherei16", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_113},
    {"compress", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_114},
    {"mv_s_x", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_115},
    {"mv1r", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_116},
    {"mv2r", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_117},
    {"mv4r", 16, 16, 4, 2, 0, 0x800000037fffffffull, expected_118},
    {"mv8r", 16, 16, 8, 3, 0, 0x800000037fffffffull, expected_119},
    {"zext2", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_120},
    {"sext2", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_121},
    {"zext4", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_122},
    {"sext4", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_123},
    {"zext8", 24, 16, 1, 0, 0, 0x800000037fffffffull, expected_124},
    {"sext8", 24, 16, 1, 1, 0, 0x800000037fffffffull, expected_125},
    {"msbf", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_126},
    {"msof", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_127},
    {"msif", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_128},
    {"iota", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_129},
    {"id", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_130},
    {"mandn", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_131},
    {"mand", 17, 16, 1, 0, 0, 0x800000037fffffffull, expected_132},
    {"mor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_133},
    {"mxor", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_134},
    {"morn", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_135},
    {"mnand", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_136},
    {"mnor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_137},
    {"mxnor", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_138},
    {"redsum", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_139},
    {"redand", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_140},
    {"redor", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_141},
    {"redxor", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_142},
    {"redminu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_143},
    {"redmin", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_144},
    {"redmaxu", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_145},
    {"redmax", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_146},
    {"wredsumu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_147},
    {"wredsum", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_148},
};
#endif
#if VEC_VLEN == 512
static const uint64_t expected_0[] = {0x2304e6c86b8dafd0ull,
                                      0x2304e6c96b8dafd0ull,
                                      0x2304e6c86b8dafd1ull,
                                      0x2304e6c96b8dafd1ull,
                                      0x2304e6c96b8dafd1ull,
                                      0x2304e6c86b8dafd1ull,
                                      0x2304e6c86b8dafd0ull,
                                      0x2304e6c96b8dafd1ull,
                                      0x2506e8cb6d8fb1d2ull,
                                      0x2506e8ca6d8fb1d3ull,
                                      0x2506e8cb6d8fb1d3ull,
                                      0x2506e8cb6d8fb1d2ull,
                                      0x2506e8ca6d8fb1d3ull,
                                      0x2506e8ca6d8fb1d3ull,
                                      0x2506e8cb6d8fb1d2ull,
                                      0x2506e8cb6d8fb1d2ull};
static const uint64_t expected_1[] = {0x097a6b5b2dbecfdfull,
                                      0x097a6b5c2dbecfdfull,
                                      0x097a6b5b2dbecfe0ull,
                                      0x097a6b5c2dbecfe0ull,
                                      0x097a6b5c2dbecfe0ull,
                                      0x097a6b5b2dbecfe0ull,
                                      0x097a6b5b2dbecfdfull,
                                      0x097a6b5c2dbecfe0ull};
static const uint64_t expected_2[] = {0x897a6b5fadbecfe3ull,
                                      0x897a6b60adbecfe3ull,
                                      0x897a6b5fadbecfe4ull,
                                      0x897a6b60adbecfe4ull,
                                      0x897a6b60adbecfe4ull,
                                      0x897a6b5fadbecfe4ull,
                                      0x897a6b5fadbecfe3ull,
                                      0x897a6b60adbecfe4ull};
static const uint64_t expected_3[] = {0x91827364ffffffffull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull};
static const uint64_t expected_4[] = {0x91827364b5c6ffffull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull};
static const uint64_t expected_5[] = {0x91827364b5c60000ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull};
static const uint64_t expected_6[] = {0xefefeff0efefeff0ull,
                                      0xefefefefefefeff0ull,
                                      0xefefeff0efefefefull,
                                      0xefefefefefefefefull,
                                      0xefefefefefefefefull,
                                      0xefefeff0efefefefull,
                                      0xefefeff0efefeff0ull,
                                      0xefefefefefefefefull,
                                      0xefefefefefefeff0ull,
                                      0xefefeff0efefefefull,
                                      0xefefefefefefefefull,
                                      0xefefefefefefeff0ull,
                                      0xefefeff0efefefefull,
                                      0xefefeff0efefefefull,
                                      0xefefefefefefeff0ull,
                                      0xefefefefefefeff0ull};
static const uint64_t expected_7[] = {0x097a6b5d2dbecfe1ull,
                                      0x097a6b5c2dbecfe1ull,
                                      0x097a6b5d2dbecfe0ull,
                                      0x097a6b5c2dbecfe0ull,
                                      0x097a6b5c2dbecfe0ull,
                                      0x097a6b5d2dbecfe0ull,
                                      0x097a6b5d2dbecfe1ull,
                                      0x097a6b5c2dbecfe0ull};
static const uint64_t expected_8[] = {0x91827364b5c6ffffull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull};
static const uint64_t expected_9[] = {0x9182736400000000ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull,
                                      0x91827364b5c6d7e8ull};
static const uint64_t expected_10[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x91827364ffffffffull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffffffffffull};
static const uint64_t expected_11[] = {0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull};
static const uint64_t expected_12[] = {0x91827364b5c6d7e8ull,
                                       0x897a6b5fb5c6d7e8ull,
                                       0x91827364adbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x91827364adbecfe3ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x8a7b6c60b6c7d8e9ull,
                                       0x92837465aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60b6c7d8e9ull,
                                       0x92837465aebfd0e4ull,
                                       0x92837465aebfd0e4ull,
                                       0x8a7b6c60b6c7d8e9ull,
                                       0x8a7b6c60b6c7d8e9ull};
static const uint64_t expected_13[] = {0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull};
static const uint64_t expected_14[] = {0x91827364b5c6d7e8ull,
                                       0x097a6b5bb5c6d7e8ull,
                                       0x918273642dbecfdfull,
                                       0x097a6b5b2dbecfdfull,
                                       0x097a6b5b2dbecfdfull,
                                       0x918273642dbecfdfull,
                                       0x91827364b5c6d7e8ull,
                                       0x097a6b5b2dbecfdfull};
static const uint64_t expected_15[] = {0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x897a6b5fadbecfe3ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull,
                                       0x8a7b6c60aebfd0e4ull};
static const uint64_t expected_16[] = {0x91827364b5c6d7e8ull,
                                       0x00000000b5c6d7e8ull,
                                       0x9182736400000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x9182736400000000ull,
                                       0x91827364b5c6d7e8ull,
                                       0x0000000000000000ull};
static const uint64_t expected_17[] = {0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull};
static const uint64_t expected_18[] = {0x91827364b5c6d7e8ull,
                                       0xefefeff0b5c6d7e8ull,
                                       0x91827364efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0x91827364efefeff0ull,
                                       0x91827364b5c6d7e8ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0x92837465efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0x92837465efefeff0ull,
                                       0x92837465efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0xefefeff0b6c7d8e9ull};
static const uint64_t expected_19[] = {0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull};
static const uint64_t expected_20[] = {0x91827364b5c6d7e8ull,
                                       0x5edf434fb5c6d7e8ull,
                                       0x918273642a892e60ull,
                                       0x5edf434f2a892e60ull,
                                       0x5edf434f2a892e60ull,
                                       0x918273642a892e60ull,
                                       0x91827364b5c6d7e8ull,
                                       0x5edf434f2a892e60ull};
static const uint64_t expected_21[] = {0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x897a6b5dadbecfe1ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull,
                                       0x8a7b6c5eaebfd0e2ull};
static const uint64_t expected_22[] = {0x91827364b5c6d7e8ull,
                                       0x000897a6b5c6d7e8ull,
                                       0x918273640000adbeull,
                                       0x000897a60000adbeull,
                                       0x000897a60000adbeull,
                                       0x918273640000adbeull,
                                       0x91827364b5c6d7e8ull,
                                       0x000897a60000adbeull};
static const uint64_t expected_23[] = {0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull};
static const uint64_t expected_24[] = {0x91827364b5c6d7e8ull,
                                       0x112f4d6cb5c6d7e8ull,
                                       0x9182736415b7d9fcull,
                                       0x112f4d6c15b7d9fcull,
                                       0x112f4d6c15b7d9fcull,
                                       0x9182736415b7d9fcull,
                                       0x91827364b5c6d7e8ull,
                                       0x112f4d6c15b7d9fcull,
                                       0x114f6d8cb6c7d8e9ull,
                                       0x9283746515d7fa1cull,
                                       0x114f6d8c15d7fa1cull,
                                       0x114f6d8cb6c7d8e9ull,
                                       0x9283746515d7fa1cull,
                                       0x9283746515d7fa1cull,
                                       0x114f6d8cb6c7d8e9ull,
                                       0x114f6d8cb6c7d8e9ull};
static const uint64_t expected_25[] = {0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull,
                                       0xfff897a7ffffadbfull};
static const uint64_t expected_26[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x91827364ffffffffull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffffffffffull};
static const uint64_t expected_27[] = {0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf12f4d6bf5b7d9fcull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull,
                                       0xf14f6d8bf5d7fa1dull};
static const uint64_t expected_28[] = {0x91827364b5c6d7e8ull,
                                       0x000897a6b5c6d7e8ull,
                                       0x918273640000897aull,
                                       0x000897a60000897aull,
                                       0x0008a7b600008a7bull,
                                       0x9182736400008a7bull,
                                       0x91827364b5c6d7e8ull,
                                       0x0008a7b600008a7bull};
static const uint64_t expected_29[] = {0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull};
static const uint64_t expected_30[] = {0x91827364b5c6d7e8ull,
                                       0x95b7d9fcb5c6d7e8ull,
                                       0x9182736495b7d9fcull,
                                       0x95b7d9fc95b7d9fcull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0x91827364b5d7fa1cull,
                                       0x91827364b5c6d7e8ull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xd5f81a3cb6c7d8e9ull,
                                       0x92837465d5f81a3cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xd5f81a3cb6c7d8e9ull,
                                       0x92837465f6183a5cull,
                                       0x92837465f6183a5cull,
                                       0xf6183a5cb6c7d8e9ull,
                                       0xf6183a5cb6c7d8e9ull};
static const uint64_t expected_31[] = {0xfff897a6ffff897aull,
                                       0xfff897a6ffff897aull,
                                       0xfff897a6ffff897aull,
                                       0xfff897a6ffff897aull,
                                       0xfff8a7b6ffff8a7bull,
                                       0xfff8a7b6ffff8a7bull,
                                       0xfff8a7b6ffff8a7bull,
                                       0xfff8a7b6ffff8a7bull};
static const uint64_t expected_32[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x91827364ffffffffull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffffffffffull};
static const uint64_t expected_33[] = {0x95b7d9fc95b7d9fcull,
                                       0x95b7d9fc95b7d9fcull,
                                       0x95b7d9fc95b7d9fcull,
                                       0x95b7d9fc95b7d9fcull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xb5d7fa1cb5d7fa1cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xd5f81a3cd5f81a3cull,
                                       0xf6183a5cf6183a5cull,
                                       0xf6183a5cf6183a5cull,
                                       0xf6183a5cf6183a5cull,
                                       0xf6183a5cf6183a5cull};
static const uint64_t expected_34[] = {0x91827364b5c6d7e8ull,
                                       0x000897a6b5c6d7e8ull,
                                       0x918273640000897aull,
                                       0x000897a60000897aull,
                                       0x0008a7b600008a7bull,
                                       0x9182736400008a7bull,
                                       0x91827364b5c6d7e8ull,
                                       0x0008a7b600008a7bull};
static const uint64_t expected_35[] = {0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull};
static const uint64_t expected_36[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x91827364ffffffffull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffffffffffull,
                                       0xffffffffb6c7d8e9ull,
                                       0x92837465ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffb6c7d8e9ull,
                                       0x92837465ffffffffull,
                                       0x92837465ffffffffull,
                                       0xffffffffb6c7d8e9ull,
                                       0xffffffffb6c7d8e9ull};
static const uint64_t expected_37[] = {0xfff897a7ffff897aull,
                                       0xfff897a7ffff897aull,
                                       0xfff897a7ffff897aull,
                                       0xfff897a7ffff897aull,
                                       0xfff8a7b7ffff8a7bull,
                                       0xfff8a7b7ffff8a7bull,
                                       0xfff8a7b7ffff8a7bull,
                                       0xfff8a7b7ffff8a7bull};
static const uint64_t expected_38[] = {0x91827364b5c6d7e8ull,
                                       0xffffffffb5c6d7e8ull,
                                       0x91827364ffffffffull,
                                       0xffffffffffffffffull,
                                       0xffffffffffffffffull,
                                       0x91827364ffffffffull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffffffffffull};
static const uint64_t expected_39[] = {0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull,
                                       0x8000000080000000ull};
static const uint64_t expected_40[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xa6b5c00000000000ull,
                                       0xcfe0000000000000ull,
                                       0x91827364b5c6d7e8ull,
                                       0xcfe0000000000000ull,
                                       0xa6b5c00000000000ull,
                                       0xcfe0000000000000ull,
                                       0xa6b5c00000000000ull,
                                       0xcfe0000000000000ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0xcfe0000000000000ull,
                                       0xa6b5c00000000000ull};
static const uint64_t expected_41[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_42[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x000000044bd35ae0ull,
    0x000000056df67f00ull, 0x91827364b5c6d7e8ull, 0x000000056df67f00ull, 0x000000044bd35ae0ull,
    0x000000056df67f00ull, 0x000000044bd35ae0ull, 0x000000056df67f00ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0x000000056df67f00ull, 0x000000044bd35ae0ull,
    0x93847566b7c8d9eaull, 0x0000000453db62e8ull, 0x0000000575fe8708ull, 0x93847566b7c8d9eaull,
    0x0000000575fe8708ull, 0x0000000453db62e8ull, 0x93847566b7c8d9eaull, 0x0000000453db62e8ull,
    0x0000000575fe8708ull, 0x94857667b8c9daebull, 0x0000000575fe8708ull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0x0000000453db62e8ull, 0x94857667b8c9daebull, 0x0000000453db62e8ull};
static const uint64_t expected_43[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_44[] = {0x91827364b5c6d7e8ull,
                                       0x897a6b5cb5c6d7e8ull,
                                       0x91827364897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x91827364897a6b5cull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5c897a6b5cull};
static const uint64_t expected_45[] = {0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull,
                                       0x897a6b5c897a6b5cull};
static const uint64_t expected_46[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull};
static const uint64_t expected_47[] = {0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull,
                                       0x84bd35ad96df67efull};
static const uint64_t expected_48[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull};
static const uint64_t expected_49[] = {0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull,
                                       0x04bd35ae16df67f0ull};
static const uint64_t expected_50[] = {0x91827364b5c6d7e8ull,
                                       0xf7f7f7f8b5c6d7e8ull,
                                       0x91827364f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0x91827364f7f7f7f8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_51[] = {0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x04bd35af16df67f1ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull,
                                       0x053db62f175fe871ull};
static const uint64_t expected_52[] = {0x91827364b5c6d7e8ull,
                                       0xf7f7f7f8b5c6d7e8ull,
                                       0x91827364f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0x91827364f7f7f7f8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_53[] = {0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull,
                                       0x84bd35ae96df67f0ull};
static const uint64_t expected_54[] = {0x91827364b5c6d7e8ull,
                                       0x00000000b5c6d7e8ull,
                                       0x9182736400000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x9182736400000000ull,
                                       0x91827364b5c6d7e8ull,
                                       0x0000000000000000ull,
                                       0x00000000b6c7d8e9ull,
                                       0x9283746500000000ull,
                                       0x0000000000000000ull,
                                       0x00000000b6c7d8e9ull,
                                       0x9283746500000000ull,
                                       0x9283746500000000ull,
                                       0x00000000b6c7d8e9ull,
                                       0x00000000b6c7d8e9ull};
static const uint64_t expected_55[] = {0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull};
static const uint64_t expected_56[] = {0x91827364b5c6d7e8ull,
                                       0x00000001b5c6d7e8ull,
                                       0x9182736400000001ull,
                                       0x0000000100000001ull,
                                       0x0000000100000001ull,
                                       0x9182736400000001ull,
                                       0x91827364b5c6d7e8ull,
                                       0x0000000100000001ull};
static const uint64_t expected_57[] = {0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull,
                                       0x0000000000000000ull};
static const uint64_t expected_58[] = {0x91827364b5c6d7e8ull,
                                       0x897a6b5cb5c6d7e8ull,
                                       0x91827364adbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x91827364adbecfe0ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5cadbecfe0ull};
static const uint64_t expected_59[] = {0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull,
                                       0x097a6b5d2dbecfe1ull};
static const uint64_t expected_60[] = {0x91827364b5c6d7e8ull,
                                       0xefefeff0b5c6d7e8ull,
                                       0x91827364efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0x91827364efefeff0ull,
                                       0x91827364b5c6d7e8ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0x92837465efefeff0ull,
                                       0xefefeff0efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0x92837465efefeff0ull,
                                       0x92837465efefeff0ull,
                                       0xefefeff0b6c7d8e9ull,
                                       0xefefeff0b6c7d8e9ull};
static const uint64_t expected_61[] = {0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull,
                                       0x897a6b5cadbecfe0ull};
static const uint64_t expected_62[] = {0x91827364b5c6d7e8ull,
                                       0x5274886fb5c6d7e8ull,
                                       0x9182736480d246ffull,
                                       0x5274886f80d246ffull,
                                       0x5274886f80d246ffull,
                                       0x9182736480d246ffull,
                                       0x91827364b5c6d7e8ull,
                                       0x5274886f80d246ffull};
static const uint64_t expected_63[] = {0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x44bd35ad56df67efull,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full,
                                       0x453db62d575fe86full};
static const uint64_t expected_64[] = {0x91827364b5c6d7e8ull,
                                       0xacd27ed0b5c6d7e8ull,
                                       0x91827364c0370200ull,
                                       0xacd27ed0c0370200ull,
                                       0xacd27ed0c0370200ull,
                                       0x91827364c0370200ull,
                                       0x91827364b5c6d7e8ull,
                                       0xacd27ed0c0370200ull};
static const uint64_t expected_65[] = {0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull,
                                       0x768594a452413020ull};
static const uint64_t expected_66[] = {0x91827364b5c6d7e8ull,
                                       0xb8ea0d03b5c6d7e8ull,
                                       0x91827364c303670full,
                                       0xb8ea0d03c303670full,
                                       0xb8ea0d03c303670full,
                                       0x91827364c303670full,
                                       0x91827364b5c6d7e8ull,
                                       0xb8ea0d03c303670full,
                                       0xb90e3715b6c7d8e9ull,
                                       0x92837465c37062bcull,
                                       0xb90e3715c37062bcull,
                                       0xb90e3715b6c7d8e9ull,
                                       0x92837465c37062bcull,
                                       0x92837465c37062bcull,
                                       0xb90e3715b6c7d8e9ull,
                                       0xb90e3715b6c7d8e9ull};
static const uint64_t expected_67[] = {0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull};
static const uint64_t expected_68[] = {0x91827364b5c6d7e8ull,
                                       0x2f6fa1a7b5c6d7e8ull,
                                       0x918273641544972full,
                                       0x2f6fa1a71544972full,
                                       0x2f6fa1a71544972full,
                                       0x918273641544972full,
                                       0x91827364b5c6d7e8ull,
                                       0x2f6fa1a71544972full};
static const uint64_t expected_69[] = {0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc4bd35aed6df67f0ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull,
                                       0xc53db62ed75fe870ull};
static const uint64_t expected_70[] = {0x91827364b5c6d7e8ull,
                                       0x91dc258cb5c6d7e8ull,
                                       0x9182736452ec5160ull,
                                       0x91dc258c52ec5160ull,
                                       0x91dc258c52ec5160ull,
                                       0x9182736452ec5160ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91dc258c52ec5160ull};
static const uint64_t expected_71[] = {0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull,
                                       0xf7f7f7f8f7f7f7f8ull};
static const uint64_t expected_72[] = {0x91827364b5c6d7e8ull,
                                       0x8118b12cb5c6d7e8ull,
                                       0x9182736408914e60ull,
                                       0x8118b12c08914e60ull,
                                       0x8118b12c08914e60ull,
                                       0x9182736408914e60ull,
                                       0x91827364b5c6d7e8ull,
                                       0x8118b12c08914e60ull,
                                       0x874af15cb6c7d8e9ull,
                                       0x928374656c69bd88ull,
                                       0x874af15c6c69bd88ull,
                                       0x874af15cb6c7d8e9ull,
                                       0x928374656c69bd88ull,
                                       0x928374656c69bd88ull,
                                       0x874af15cb6c7d8e9ull,
                                       0x874af15cb6c7d8e9ull};
static const uint64_t expected_73[] = {0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull};
static const uint64_t expected_74[] = {0x91827364b5c6d7e8ull,
                                       0x3e54f234b5c6d7e8ull,
                                       0x9182736475fdd9e8ull,
                                       0x3e54f23475fdd9e8ull,
                                       0x3e54f23475fdd9e8ull,
                                       0x9182736475fdd9e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x3e54f23475fdd9e8ull};
static const uint64_t expected_75[] = {0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x0808080808080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull,
                                       0x8808080888080808ull};
static const uint64_t expected_76[] = {0x91827364b5c6d7e8ull,
                                       0xe4aff494b5c6d7e8ull,
                                       0x91827364f58fd5e8ull,
                                       0xe4aff494f58fd5e8ull,
                                       0xe4aff494f58fd5e8ull,
                                       0x91827364f58fd5e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xe4aff494f58fd5e8ull};
static const uint64_t expected_77[] = {0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull,
                                       0x1afcdec06385a7c8ull};
static const uint64_t expected_78[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x000000012304e6c8ull,
    0x000000016b8dafd0ull, 0x91827364b5c6d7e8ull, 0x000000016b8dafd0ull, 0x000000012304e6c8ull,
    0x000000016b8dafd0ull, 0x000000012304e6c8ull, 0x000000016b8dafd0ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0x000000016b8dafd0ull, 0x000000012304e6c8ull,
    0x93847566b7c8d9eaull, 0x000000012506e8caull, 0x000000016d8fb1d2ull, 0x93847566b7c8d9eaull,
    0x000000016d8fb1d2ull, 0x000000012506e8caull, 0x93847566b7c8d9eaull, 0x000000012506e8caull,
    0x000000016d8fb1d2ull, 0x94857667b8c9daebull, 0x000000016d8fb1d2ull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0x000000012506e8caull, 0x94857667b8c9daebull, 0x000000012506e8caull};
static const uint64_t expected_79[] = {0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull,
                                       0x000000012dbecfdfull,
                                       0x00000001097a6b5bull};
static const uint64_t expected_80[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffff2304e6c8ull,
                                       0xffffffff6b8dafd0ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffff6b8dafd0ull,
                                       0xffffffff2304e6c8ull,
                                       0xffffffff6b8dafd0ull,
                                       0xffffffff2304e6c8ull,
                                       0xffffffff6b8dafd0ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffff6b8dafd0ull,
                                       0xffffffff2304e6c8ull};
static const uint64_t expected_81[] = {
    0x000000002dbecfdfull, 0x00000000097a6b5bull, 0x000000002dbecfdfull, 0x00000000097a6b5bull,
    0x000000002dbecfdfull, 0x00000000097a6b5bull, 0x000000002dbecfdfull, 0x00000000097a6b5bull,
    0x000000002dbecfdfull, 0x00000000097a6b5bull, 0x000000002dbecfdfull, 0x00000000097a6b5bull,
    0x000000002dbecfdfull, 0x00000000097a6b5bull, 0x000000002dbecfdfull, 0x00000000097a6b5bull,
    0x000000002ebfd0e0ull, 0x000000000a7b6c5cull, 0x000000002ebfd0e0ull, 0x000000000a7b6c5cull,
    0x000000002ebfd0e0ull, 0x000000000a7b6c5cull, 0x000000002ebfd0e0ull, 0x000000000a7b6c5cull,
    0x000000002ebfd0e0ull, 0x000000000a7b6c5cull, 0x000000002ebfd0e0ull, 0x000000000a7b6c5cull,
    0x000000002ebfd0e0ull, 0x000000000a7b6c5cull, 0x000000002ebfd0e0ull, 0x000000000a7b6c5cull};
static const uint64_t expected_82[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x91827364b5c6d7e8ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0xffffffffefefeff0ull,
                                       0xffffffffefefeff0ull};
static const uint64_t expected_83[] = {0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull,
                                       0x000000002dbecfe1ull,
                                       0x00000000097a6b5dull};
static const uint64_t expected_84[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0xffffffffefefeff0ull,
    0xffffffffefefeff0ull, 0x91827364b5c6d7e8ull, 0xffffffffefefeff0ull, 0xffffffffefefeff0ull,
    0xffffffffefefeff0ull, 0xffffffffefefeff0ull, 0xffffffffefefeff0ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0xffffffffefefeff0ull, 0xffffffffefefeff0ull,
    0x93847566b7c8d9eaull, 0xffffffffefefeff0ull, 0xffffffffefefeff0ull, 0x93847566b7c8d9eaull,
    0xffffffffefefeff0ull, 0xffffffffefefeff0ull, 0x93847566b7c8d9eaull, 0xffffffffefefeff0ull,
    0xffffffffefefeff0ull, 0x94857667b8c9daebull, 0xffffffffefefeff0ull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0xffffffffefefeff0ull, 0x94857667b8c9daebull, 0xffffffffefefeff0ull};
static const uint64_t expected_85[] = {0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull,
                                       0xffffffff2dbecfe1ull,
                                       0xffffffff097a6b5dull};
static const uint64_t expected_86[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5d47494b4cull,
                                       0x897a6b5d6b8dafd0ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5d6b8dafd0ull,
                                       0x897a6b5d47494b4cull,
                                       0x8a7b6c5e6c8eb0d1ull,
                                       0x8a7b6c5e484a4c4dull,
                                       0x8a7b6c5e6c8eb0d1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5e6c8eb0d1ull,
                                       0x8a7b6c5e484a4c4dull};
static const uint64_t expected_87[] = {
    0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull,
    0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull, 0x897a6b5d2dbecfdfull,
    0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull,
    0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull, 0x8a7b6c5e2ebfd0e0ull,
    0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull,
    0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull, 0x8b7c6d5f2fc0d1e1ull,
    0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull,
    0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull, 0x8c7d6e6030c1d2e2ull};
static const uint64_t expected_88[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5c47494b4cull,
                                       0x897a6b5c6b8dafd0ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5c6b8dafd0ull,
                                       0x897a6b5c47494b4cull,
                                       0x8a7b6c5d6c8eb0d1ull,
                                       0x8a7b6c5d484a4c4dull,
                                       0x8a7b6c5d6c8eb0d1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5d6c8eb0d1ull,
                                       0x8a7b6c5d484a4c4dull};
static const uint64_t expected_89[] = {0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x897a6b5d2dbecfdfull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull,
                                       0x8a7b6c5e2ebfd0e0ull};
static const uint64_t expected_90[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x897a6b5c14345474ull,
    0x897a6b5befefeff0ull, 0x91827364b5c6d7e8ull, 0x897a6b5befefeff0ull, 0x897a6b5c14345474ull,
    0x8a7b6c5cf0f0f0f1ull, 0x8a7b6c5d15355575ull, 0x8a7b6c5cf0f0f0f1ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0x8a7b6c5cf0f0f0f1ull, 0x8a7b6c5d15355575ull,
    0x93847566b7c8d9eaull, 0x8b7c6d5e15355575ull, 0x8b7c6d5df0f0f0f1ull, 0x93847566b7c8d9eaull,
    0x8b7c6d5df0f0f0f1ull, 0x8b7c6d5e15355575ull, 0x93847566b7c8d9eaull, 0x8b7c6d5e15355575ull,
    0x8c7d6e5ef1f1f1f2ull, 0x94857667b8c9daebull, 0x8c7d6e5ef1f1f1f2ull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0x8c7d6e5f16365676ull, 0x94857667b8c9daebull, 0x8c7d6e5f16365676ull};
static const uint64_t expected_91[] = {0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x897a6b5c2dbecfe1ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull,
                                       0x8a7b6c5d2ebfd0e2ull};
static const uint64_t expected_92[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5d14345474ull,
                                       0x897a6b5cefefeff0ull,
                                       0x91827364b5c6d7e8ull,
                                       0x897a6b5cefefeff0ull,
                                       0x897a6b5d14345474ull,
                                       0x8a7b6c5df0f0f0f1ull,
                                       0x8a7b6c5e15355575ull,
                                       0x8a7b6c5df0f0f0f1ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x8a7b6c5df0f0f0f1ull,
                                       0x8a7b6c5e15355575ull};
static const uint64_t expected_93[] = {
    0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull,
    0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull, 0x897a6b5c2dbecfe1ull,
    0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull,
    0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull, 0x8a7b6c5d2ebfd0e2ull,
    0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull,
    0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull, 0x8b7c6d5e2fc0d1e3ull,
    0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull,
    0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull, 0x8c7d6e5f30c1d2e4ull};
static const uint64_t expected_94[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x5274886facd27ed0ull,
                                       0x80d246ffc0370200ull,
                                       0x91827364b5c6d7e8ull,
                                       0x80d246ffc0370200ull,
                                       0x5274886facd27ed0ull,
                                       0x80d246ffc0370200ull,
                                       0x5274886facd27ed0ull,
                                       0x80d246ffc0370200ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x80d246ffc0370200ull,
                                       0x5274886facd27ed0ull};
static const uint64_t expected_95[] = {0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull,
                                       0x56df67ef52413020ull,
                                       0x44bd35ad768594a4ull};
static const uint64_t expected_96[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0xb8ea0d03acd27ed0ull,
    0xc303670fc0370200ull, 0x91827364b5c6d7e8ull, 0xc303670fc0370200ull, 0xb8ea0d03acd27ed0ull,
    0xc303670fc0370200ull, 0xb8ea0d03acd27ed0ull, 0xc303670fc0370200ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0xc303670fc0370200ull, 0xb8ea0d03acd27ed0ull,
    0x93847566b7c8d9eaull, 0xb90e371587892f99ull, 0xc37062bc3d4783d1ull, 0x93847566b7c8d9eaull,
    0xc37062bc3d4783d1ull, 0xb90e371587892f99ull, 0x93847566b7c8d9eaull, 0xb90e371587892f99ull,
    0xc37062bc3d4783d1ull, 0x94857667b8c9daebull, 0xc37062bc3d4783d1ull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0xb90e371587892f99ull, 0x94857667b8c9daebull, 0xb90e371587892f99ull};
static const uint64_t expected_97[] = {0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull,
                                       0xd6df67f052413020ull,
                                       0xc4bd35ae768594a4ull};
static const uint64_t expected_98[] = {0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x91827364b5c6d7e8ull,
                                       0x2f6fa1a7acd27ed0ull,
                                       0x1544972fc0370200ull,
                                       0x91827364b5c6d7e8ull,
                                       0x1544972fc0370200ull,
                                       0x2f6fa1a7acd27ed0ull,
                                       0x1544972fc0370200ull,
                                       0x2f6fa1a7acd27ed0ull,
                                       0x1544972fc0370200ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x92837465b6c7d8e9ull,
                                       0x1544972fc0370200ull,
                                       0x2f6fa1a7acd27ed0ull};
static const uint64_t expected_99[] = {
    0xd6df67f052413020ull, 0xc4bd35ae768594a4ull, 0xd6df67f052413020ull, 0xc4bd35ae768594a4ull,
    0xd6df67f052413020ull, 0xc4bd35ae768594a4ull, 0xd6df67f052413020ull, 0xc4bd35ae768594a4ull,
    0xd6df67f052413020ull, 0xc4bd35ae768594a4ull, 0xd6df67f052413020ull, 0xc4bd35ae768594a4ull,
    0xd6df67f052413020ull, 0xc4bd35ae768594a4ull, 0xd6df67f052413020ull, 0xc4bd35ae768594a4ull,
    0xd75fe870d1402f1full, 0xc53db62ef58493a3ull, 0xd75fe870d1402f1full, 0xc53db62ef58493a3ull,
    0xd75fe870d1402f1full, 0xc53db62ef58493a3ull, 0xd75fe870d1402f1full, 0xc53db62ef58493a3ull,
    0xd75fe870d1402f1full, 0xc53db62ef58493a3ull, 0xd75fe870d1402f1full, 0xc53db62ef58493a3ull,
    0xd75fe870d1402f1full, 0xc53db62ef58493a3ull, 0xd75fe870d1402f1full, 0xc53db62ef58493a3ull};
static const uint64_t expected_100[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0xe3f6fbd4629956b8ull,
                                        0x1254ba6475fdd9e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x1254ba6475fdd9e8ull,
                                        0xe3f6fbd4629956b8ull,
                                        0x1355bb6576fedae9ull,
                                        0xe4f7fcd5639a57b9ull,
                                        0x1355bb6576fedae9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x1355bb6576fedae9ull,
                                        0xe4f7fcd5639a57b9ull};
static const uint64_t expected_101[] = {0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe861db5408080808ull,
                                        0xd63fa9122c4c6c8cull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull,
                                        0xe962dc5509090909ull,
                                        0xd740aa132d4d6d8dull};
static const uint64_t expected_102[] = {
    0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0x91827364b5c6d7e8ull, 0xc0f2150c629956b8ull,
    0xa6c70a9475fdd9e8ull, 0x91827364b5c6d7e8ull, 0xa6c70a9475fdd9e8ull, 0xc0f2150c629956b8ull,
    0xa7c80b9576fedae9ull, 0xc1f3160d639a57b9ull, 0xa7c80b9576fedae9ull, 0x92837465b6c7d8e9ull,
    0x92837465b6c7d8e9ull, 0x92837465b6c7d8e9ull, 0xa7c80b9576fedae9ull, 0xc1f3160d639a57b9ull,
    0x93847566b7c8d9eaull, 0xc217401f3f520983ull, 0xa8350741f5105dbbull, 0x93847566b7c8d9eaull,
    0xa8350741f5105dbbull, 0xc217401f3f520983ull, 0x93847566b7c8d9eaull, 0xc217401f3f520983ull,
    0xa9360842f6115ebcull, 0x94857667b8c9daebull, 0xa9360842f6115ebcull, 0x94857667b8c9daebull,
    0x94857667b8c9daebull, 0xc318412040530a84ull, 0x94857667b8c9daebull, 0xc318412040530a84ull};
static const uint64_t expected_103[] = {0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull};
static const uint64_t expected_104[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x5a7c9078629956b8ull,
                                        0x6495ea8475fdd9e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x6495ea8475fdd9e8ull,
                                        0x5a7c9078629956b8ull,
                                        0x6596eb8576fedae9ull,
                                        0x5b7d9179639a57b9ull,
                                        0x6596eb8576fedae9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x6596eb8576fedae9ull,
                                        0x5b7d9179639a57b9ull};
static const uint64_t expected_105[] = {
    0xe861db5408080808ull, 0xd63fa9122c4c6c8cull, 0xe861db5408080808ull, 0xd63fa9122c4c6c8cull,
    0xe861db5408080808ull, 0xd63fa9122c4c6c8cull, 0xe861db5408080808ull, 0xd63fa9122c4c6c8cull,
    0xe962dc5509090909ull, 0xd740aa132d4d6d8dull, 0xe962dc5509090909ull, 0xd740aa132d4d6d8dull,
    0xe962dc5509090909ull, 0xd740aa132d4d6d8dull, 0xe962dc5509090909ull, 0xd740aa132d4d6d8dull,
    0xeae45dd689090909ull, 0xd8c22b94ad4d6d8dull, 0xeae45dd689090909ull, 0xd8c22b94ad4d6d8dull,
    0xeae45dd689090909ull, 0xd8c22b94ad4d6d8dull, 0xeae45dd689090909ull, 0xd8c22b94ad4d6d8dull,
    0xebe55ed78a0a0a0aull, 0xd9c32c95ae4e6e8eull, 0xebe55ed78a0a0a0aull, 0xd9c32c95ae4e6e8eull,
    0xebe55ed78a0a0a0aull, 0xd9c32c95ae4e6e8eull, 0xebe55ed78a0a0a0aull, 0xd9c32c95ae4e6e8eull};
static const uint64_t expected_106[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6861db5508080808ull,
                                        0x91827364b5c6d7e8ull,
                                        0x6861db5508080808ull,
                                        0x563fa9132c4c6c8cull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull,
                                        0x6962dc5609090909ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x6962dc5609090909ull,
                                        0x5740aa142d4d6d8dull};
static const uint64_t expected_107[] = {0x91827364b5c6d7e8ull,
                                        0xadbecfe0b5c6d7e8ull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull};
static const uint64_t expected_108[] = {0x91827364b5c6d7e8ull,
                                        0xadbecfe0b5c6d7e8ull,
                                        0x91827364897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0x91827364897a6b5cull,
                                        0x91827364b5c6d7e8ull,
                                        0xadbecfe0897a6b5cull,
                                        0xaebfd0e1b6c7d8e9ull,
                                        0x928374658a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e1b6c7d8e9ull,
                                        0x928374658a7b6c5dull,
                                        0x928374658a7b6c5dull,
                                        0xaebfd0e1b6c7d8e9ull,
                                        0xaebfd0e1b6c7d8e9ull};
static const uint64_t expected_109[] = {0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0x00000000897a6b5cull,
                                        0x0000000000000000ull};
static const uint64_t expected_110[] = {0x91827364b5c6d7e8ull,
                                        0xadbecfe0b5c6d7e8ull,
                                        0x91827364897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0x91827364897a6b5cull,
                                        0x91827364b5c6d7e8ull,
                                        0x00000000897a6b5cull};
static const uint64_t expected_111[] = {0xadbecfe000000001ull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xaebfd0e1897a6b5cull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull,
                                        0xaebfd0e18a7b6c5dull};
static const uint64_t expected_112[] = {0x91827364b5c6d7e8ull,
                                        0xadbecfe0b5c6d7e8ull,
                                        0x91827364897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0xadbecfe0897a6b5cull,
                                        0x91827364897a6b5cull,
                                        0x91827364b5c6d7e8ull,
                                        0x00000001897a6b5cull};
static const uint64_t expected_113[] = {0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull};
static const uint64_t expected_114[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0xadbecfe0adbecfe0ull,
                                        0x8a7b6c5d897a6b5cull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0xaebfd0e1aebfd0e1ull,
                                        0xaebfd0e18a7b6c5dull,
                                        0x8a7b6c5d8a7b6c5dull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull,
                                        0x92837465b6c7d8e9ull};
static const uint64_t expected_115[] = {0x918273647fffffffull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_116[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull};
static const uint64_t expected_117[] = {0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x897a6b5cadbecfe0ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull,
                                        0x8a7b6c5daebfd0e1ull};
static const uint64_t expected_118[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull,
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull,
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull,
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull,
    0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull,
    0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull,
    0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull,
    0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull};
static const uint64_t expected_119[] = {
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull,
    0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull, 0x897a6b5cadbecfe0ull,
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull,
    0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull, 0x8a7b6c5daebfd0e1ull,
    0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull,
    0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull, 0x8b7c6d5eafc0d1e2ull,
    0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull,
    0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull, 0x8c7d6e5fb0c1d2e3ull,
    0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull,
    0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull, 0x8d7e6f60b1c2d3e4ull,
    0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull,
    0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull, 0x8e7f7061b2c3d4e5ull,
    0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull,
    0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull, 0x8f807162b3c4d5e6ull,
    0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull,
    0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull, 0x90817263b4c5d6e7ull};
static const uint64_t expected_120[] = {0x91827364b5c6d7e8ull,
                                        0x0000897ab5c6d7e8ull,
                                        0x918273640000cfe0ull,
                                        0x0000897a00006b5cull,
                                        0x0000adbe0000cfe0ull,
                                        0x9182736400006b5cull,
                                        0x91827364b5c6d7e8ull,
                                        0x0000897a00006b5cull,
                                        0x0000adbeb6c7d8e9ull,
                                        0x9283746500006b5cull,
                                        0x0000adbe0000cfe0ull,
                                        0x0000897ab6c7d8e9ull,
                                        0x928374650000cfe0ull,
                                        0x9283746500006b5cull,
                                        0x0000adbeb6c7d8e9ull,
                                        0x0000897ab6c7d8e9ull};
static const uint64_t expected_121[] = {0xffffadbeffffcfe0ull,
                                        0xffff897a00006b5cull,
                                        0xffffadbeffffcfe0ull,
                                        0xffff897a00006b5cull,
                                        0xffffadbeffffcfe0ull,
                                        0xffff897a00006b5cull,
                                        0xffffadbeffffcfe0ull,
                                        0xffff897a00006b5cull};
static const uint64_t expected_122[] = {0x91827364b5c6d7e8ull,
                                        0x000000adb5c6d7e8ull,
                                        0x918273640000005cull,
                                        0x000000890000007aull,
                                        0x000000cf000000e0ull,
                                        0x91827364000000beull,
                                        0x91827364b5c6d7e8ull,
                                        0x000000890000007aull};
static const uint64_t expected_123[] = {0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull,
                                        0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull,
                                        0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull,
                                        0xffffffcfffffffe0ull,
                                        0xffffffadffffffbeull,
                                        0x0000006b0000005cull,
                                        0xffffff890000007aull};
static const uint64_t expected_124[] = {0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x00000000000000adull,
                                        0x000000000000005cull,
                                        0x91827364b5c6d7e8ull,
                                        0x000000000000007aull,
                                        0x0000000000000089ull};
static const uint64_t expected_125[] = {0xffffffffffffffe0ull,
                                        0xffffffffffffffcfull,
                                        0xffffffffffffffbeull,
                                        0xffffffffffffffadull,
                                        0x000000000000005cull,
                                        0x000000000000006bull,
                                        0x000000000000007aull,
                                        0xffffffffffffff89ull};
static const uint64_t expected_126[] = {0x9182736410401038ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_127[] = {0x91827364b5c60020ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_128[] = {0x91827364b5c61078ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_129[] = {0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000000000000ull,
                                        0x0000000200000001ull,
                                        0x0000000400000003ull,
                                        0x0000000600000005ull,
                                        0x0000000700000007ull,
                                        0x0000000800000007ull,
                                        0x0000000900000009ull,
                                        0x0000000b0000000aull,
                                        0x0000000d0000000cull,
                                        0x0000000e0000000eull,
                                        0x000000100000000full,
                                        0x0000001100000010ull,
                                        0x0000001200000012ull,
                                        0x0000001300000013ull};
static const uint64_t expected_130[] = {0x91827364b5c6d7e8ull,
                                        0x00000003b5c6d7e8ull,
                                        0x9182736400000004ull,
                                        0x0000000700000006ull,
                                        0x0000000900000008ull,
                                        0x918273640000000aull,
                                        0x91827364b5c6d7e8ull,
                                        0x0000000f0000000eull};
static const uint64_t expected_131[] = {0x91827364b5c60000ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_132[] = {0x91827364ad8ecfe0ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_133[] = {0x91827364b5c6dff0ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_134[] = {0x91827364b5c61010ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_135[] = {0x91827364efbfefefull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_136[] = {0x91827364b5c6301full,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_137[] = {0x91827364b5c6200full,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_138[] = {0x91827364ef8fefefull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull,
                                        0x91827364b5c6d7e8ull};
static const uint64_t expected_139[] = {0x867768596283a4bbull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_140[] = {0x8677685988384a40ull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_141[] = {0x86776859adffefffull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_142[] = {0x867768590507053bull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_143[] = {0x86776859897a6b5cull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_144[] = {0x86776859897a6b5cull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_145[] = {0x86776859adbecfe0ull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_146[] = {0x86776859adbecfe0ull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_147[] = {0x847566616283a4bbull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const uint64_t expected_148[] = {0x84756654335d87abull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull,
                                        0x86776859aabbccddull};
static const struct test_case cases[] = {
    {"adc", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_0},
    {"adc", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_1},
    {"adc", 16, 16, 1, 2, 0, 0x0000000000000003ull, expected_2},
    {"madc", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_3},
    {"madc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_4},
    {"madc", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_5},
    {"sbc", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_6},
    {"sbc", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_7},
    {"msbc", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_8},
    {"msbc", 17, 16, 1, 1, 0, 0x800000037fffffffull, expected_9},
    {"saddu", 16, 16, 1, 2, 1, 0x800000037fffffffull, expected_10},
    {"saddu", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_11},
    {"saddu", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_12},
    {"sadd", 16, 16, 1, 1, 1, 0x800000037fffffffull, expected_13},
    {"sadd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_14},
    {"sadd", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_15},
    {"ssubu", 16, 16, 1, 0, 1, 0x800000037fffffffull, expected_16},
    {"ssubu", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_17},
    {"ssub", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_18},
    {"ssub", 16, 16, 1, 3, 1, 0x800000037fffffffull, expected_19},
    {"smul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_20},
    {"smul", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_21},
    {"ssrl", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_22},
    {"ssrl", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_23},
    {"ssrl", 17, 16, 2, 0, 0, 0x0000000000000003ull, expected_24},
    {"ssra", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_25},
    {"ssra", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_26},
    {"ssra", 17, 16, 2, 3, 0, 0x0000000000000003ull, expected_27},
    {"nsrl", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_28},
    {"nsrl", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_29},
    {"nsrl", 17, 16, 2, 2, 0, 0x0000000000000003ull, expected_30},
    {"nsra", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_31},
    {"nsra", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_32},
    {"nsra", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_33},
    {"nclipu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_34},
    {"nclipu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_35},
    {"nclipu", 17, 16, 2, 0, 1, 0x0000000000000003ull, expected_36},
    {"nclip", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_37},
    {"nclip", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_38},
    {"nclip", 17, 16, 2, 3, 1, 0x0000000000000003ull, expected_39},
    {"wsll", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_40},
    {"wsll", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_41},
    {"wsll", 17, 16, 4, 2, 0, 0x0000000000000003ull, expected_42},
    {"rgather", 16, 16, 1, 3, 0, 0x0000000000000001ull, expected_43},
    {"rgather", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_44},
    {"rgather", 17, 16, 2, 1, 0, 0x0000000000000003ull, expected_45},
    {"aaddu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_46},
    {"aaddu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_47},
    {"aadd", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_48},
    {"aadd", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_49},
    {"asubu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_50},
    {"asubu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_51},
    {"asub", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_52},
    {"asub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_53},
    {"divu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_54},
    {"divu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_55},
    {"div", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_56},
    {"div", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_57},
    {"remu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_58},
    {"remu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_59},
    {"rem", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_60},
    {"rem", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_61},
    {"mulhu", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_62},
    {"mulhu", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_63},
    {"mul", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_64},
    {"mul", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_65},
    {"mulhsu", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_66},
    {"mulhsu", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_67},
    {"mulh", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_68},
    {"mulh", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_69},
    {"madd", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_70},
    {"madd", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_71},
    {"nmsub", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_72},
    {"nmsub", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_73},
    {"macc", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_74},
    {"macc", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_75},
    {"nmsac", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_76},
    {"nmsac", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_77},
    {"waddu", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_78},
    {"waddu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_79},
    {"wadd", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_80},
    {"wadd", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_81},
    {"wsubu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_82},
    {"wsubu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_83},
    {"wsub", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_84},
    {"wsub", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_85},
    {"waddu_w", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_86},
    {"waddu_w", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_87},
    {"wadd_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_88},
    {"wadd_w", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_89},
    {"wsubu_w", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_90},
    {"wsubu_w", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_91},
    {"wsub_w", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_92},
    {"wsub_w", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_93},
    {"wmulu", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_94},
    {"wmulu", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_95},
    {"wmulsu", 17, 16, 4, 0, 0, 0x800000037fffffffull, expected_96},
    {"wmulsu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_97},
    {"wmul", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_98},
    {"wmul", 17, 16, 4, 3, 0, 0x800000037fffffffull, expected_99},
    {"wmaccu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_100},
    {"wmaccu", 16, 16, 2, 1, 0, 0x800000037fffffffull, expected_101},
    {"wmacc", 17, 16, 4, 2, 0, 0x800000037fffffffull, expected_102},
    {"wmacc", 16, 16, 2, 3, 0, 0x800000037fffffffull, expected_103},
    {"wmaccsu", 16, 16, 2, 0, 0, 0x800000037fffffffull, expected_104},
    {"wmaccsu", 17, 16, 4, 1, 0, 0x800000037fffffffull, expected_105},
    {"wmaccus", 16, 16, 2, 2, 0, 0x800000037fffffffull, expected_106},
    {"slideup", 16, 16, 1, 3, 0, 0x0000000000000003ull, expected_107},
    {"slideup", 17, 16, 2, 0, 0, 0x0000000000000001ull, expected_108},
    {"slidedown", 16, 16, 1, 1, 0, 0x0000000000000003ull, expected_109},
    {"slidedown", 16, 16, 1, 2, 0, 0x0000000000000001ull, expected_110},
    {"slide1up", 17, 16, 2, 3, 0, 0x0000000000000001ull, expected_111},
    {"slide1down", 16, 16, 1, 0, 0, 0x0000000000000001ull, expected_112},
    {"rgatherei16", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_113},
    {"compress", 17, 16, 2, 2, 0, 0x800000037fffffffull, expected_114},
    {"mv_s_x", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_115},
    {"mv1r", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_116},
    {"mv2r", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_117},
    {"mv4r", 16, 16, 4, 2, 0, 0x800000037fffffffull, expected_118},
    {"mv8r", 16, 16, 8, 3, 0, 0x800000037fffffffull, expected_119},
    {"zext2", 17, 16, 2, 0, 0, 0x800000037fffffffull, expected_120},
    {"sext2", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_121},
    {"zext4", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_122},
    {"sext4", 17, 16, 2, 3, 0, 0x800000037fffffffull, expected_123},
    {"zext8", 24, 16, 1, 0, 0, 0x800000037fffffffull, expected_124},
    {"sext8", 24, 16, 1, 1, 0, 0x800000037fffffffull, expected_125},
    {"msbf", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_126},
    {"msof", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_127},
    {"msif", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_128},
    {"iota", 17, 16, 2, 1, 0, 0x800000037fffffffull, expected_129},
    {"id", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_130},
    {"mandn", 16, 16, 1, 3, 0, 0x800000037fffffffull, expected_131},
    {"mand", 17, 16, 1, 0, 0, 0x800000037fffffffull, expected_132},
    {"mor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_133},
    {"mxor", 16, 16, 1, 2, 0, 0x800000037fffffffull, expected_134},
    {"morn", 17, 16, 1, 3, 0, 0x800000037fffffffull, expected_135},
    {"mnand", 16, 16, 1, 0, 0, 0x800000037fffffffull, expected_136},
    {"mnor", 16, 16, 1, 1, 0, 0x800000037fffffffull, expected_137},
    {"mxnor", 17, 16, 1, 2, 0, 0x800000037fffffffull, expected_138},
    {"redsum", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_139},
    {"redand", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_140},
    {"redor", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_141},
    {"redxor", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_142},
    {"redminu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_143},
    {"redmin", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_144},
    {"redmaxu", 16, 5, 1, 1, 0, 0x800000037fffffffull, expected_145},
    {"redmax", 16, 5, 1, 2, 0, 0x800000037fffffffull, expected_146},
    {"wredsumu", 16, 5, 1, 3, 0, 0x800000037fffffffull, expected_147},
    {"wredsum", 16, 5, 1, 0, 0, 0x800000037fffffffull, expected_148},
};
#endif

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "vector length");
    for (unsigned k = 0; k < sizeof(cases) / sizeof(cases[0]); k++) {
        const struct test_case *t = &cases[k];
        setvl(~0ul, 24);
        for (unsigned r = 0; r < 32; r++)
            splat(r, 0x81726354a5b6c7d8ull + r * 0x0101010101010101ull);
        setvl(~0ul, t->vt);
        VT_CSR_WRITE(vxrm, t->rm);
        VT_CSR_WRITE(vxsat, 0);
        operation(k, t->scalar);
        VT_EQ(VT_CSR_READ(vxsat), t->sat, t->name);
        VT_EQ(VT_CSR_READ(vstart), 0, "vstart clears");
        setvl(~0ul, 24);
        for (unsigned r = 0; r < t->regs; r++) {
            for (unsigned word = 0; word < VEC_VLEN / 64; word++) {
                uint64_t expected = t->expected[r * (VEC_VLEN / 64) + word];
#ifdef VEC_NEGATIVE_CONTROL
                if (k == 0 && r == 0 && word == 0)
                    expected ^= 1;
#endif
                VT_EQ(extract(t->vd + r), expected, t->name);
            }
        }
        VT_EQ(vt_trap_count, 0, "legal arithmetic does not trap");
    }
    return vt_finish("vec_integer_test");
}
