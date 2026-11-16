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


/* A completed vector memory instruction clears vstart for following arithmetic. */
#include "../vec_common/vec_test.h"
#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif

#define BUFFER 0x83000000ul
#define CONFIG_REG ".insn r 0x57, 7, 0x40, x0, a2, a3\n"
#define CONFIG_IMM ".word 0x0c067057\n" /* vsetvli x0,a2,e8,m1,ta,ma */
#define LOAD ".word 0x02058087\n"       /* vle8.v v1,(a1) */
#define LOAD_MASK ".word 0x00058087\n"  /* vle8.v v1,(a1),v0.t */
#define STORE ".word 0x020580a7\n"      /* vse8.v v1,(a1) */
#define STORE_MASK ".word 0x000580a7\n" /* vse8.v v1,(a1),v0.t */
#define START "csrw vstart,a4\n"
#define ADD ".word 0x02320157\n" /* vadd.vv v2,v3,v4 */
#define NOP ".word 0x00000013\n"

static unsigned long result_element(void)
{
    register unsigned long value __asm__("a0");
    __asm__ volatile(".word 0x42202557" : "=r"(value) : : "memory");
    return value;
}

#define RUN(label, body, restart)                                                                  \
    do {                                                                                           \
        register unsigned long avl __asm__("a2") = 16;                                             \
        register unsigned long vtr __asm__("a3") = 0xc0;                                           \
        register unsigned long start __asm__("a4") = (restart);                                    \
        register unsigned long address __asm__("a1") = BUFFER;                                     \
        __asm__ volatile(CONFIG_REG : : "r"(avl), "r"(vtr) : "memory");                            \
        VT_CSR_WRITE(vstart, 0);                                                                   \
        vt_trap_clear();                                                                           \
        __asm__ volatile(".option push\n.option norvc\n" body ".option pop\n"                      \
                         :                                                                         \
                         : "r"(avl), "r"(vtr), "r"(start), "r"(address)                            \
                         : "memory");                                                              \
        VT_EQ(vt_trap_count, 0, label " trap count");                                              \
        VT_EQ(vt_trap_tval, 0, label " trap instruction");                                         \
        VT_EQ(vt_trap_vstart, 0, label " architectural restart at trap");                          \
        VT_EQ(VT_CSR_READ(vstart), 0, label " vstart after arithmetic");                           \
        VT_EQ(result_element(), 3, label " arithmetic result");                                    \
        VT_EQ(VT_CSR_READ(vl), 16, label " vl preserved");                                         \
    } while (0)

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "configured vector length");
    for (unsigned i = 0; i < 64; i++)
        ((volatile uint8_t *) BUFFER)[i] = (uint8_t) i;
    /* Prepare operands once, outside every configuration/CSR/memory window. */
    __asm__ volatile(".word 0xcc087057\n" /* vsetivli x0,16,e8,m1,ta,ma */
                     ".word 0x5e0ab057\n" /* mixed mask bytes 0xf5 */
                     ".word 0x5e06b157\n" /* vmv.v.i v2,13 */
                     ".word 0x5e00b1d7\n" /* vmv.v.i v3,1 */
                     ".word 0x5e013257\n" /* vmv.v.i v4,2 */
                     :
                     :
                     : "memory");
    VT_CSR_WRITE(vstart, 0);
    for (unsigned high = 0; high < 2; high++) {
        unsigned long restart = high ? 15 : 1;
        RUN("register load", CONFIG_REG START LOAD ADD, restart);
        RUN("register masked load", CONFIG_REG START LOAD_MASK ADD, restart);
        RUN("register store", CONFIG_REG START STORE ADD, restart);
        RUN("register masked store", CONFIG_REG START STORE_MASK ADD, restart);
        RUN("immediate load", CONFIG_IMM START LOAD ADD, restart);
        RUN("immediate masked load", CONFIG_IMM START LOAD_MASK ADD, restart);
        RUN("immediate store", CONFIG_IMM START STORE ADD, restart);
        RUN("immediate masked store", CONFIG_IMM START STORE_MASK ADD, restart);
    }
    RUN("without configuration", START LOAD ADD, 1);
    RUN("delay before CSR", CONFIG_IMM NOP START LOAD ADD, 1);
    RUN("delay after CSR", CONFIG_IMM START NOP LOAD ADD, 1);
    return vt_finish("vec_vstart_reload_test");
}
