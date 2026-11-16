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


/* The first vector instruction after reset is register-form vsetvl. */
#include "../vec_common/vec_test.h"

#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_EQ(VT_CSR_READ(vtype), 1ul << 63, "reset vtype is vill");
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "configured vector length");
    register unsigned long avl __asm__("a0") = ~0ul;
    register unsigned long vtype __asm__("t0") = 0x18;
    register unsigned long vl __asm__("t1");
    __asm__ volatile(".option push\n.option norvc\n"
                     ".insn r 0x57, 7, 0x40, t1, a0, t0\n"
                     ".word 0x022180d7\n" /* vadd.vv v1, v2, v3 */
                     ".option pop\n"
                     : "=r"(vl)
                     : "r"(avl), "r"(vtype)
                     : "memory");
    VT_EQ(vl, VEC_VLEN / 64, "vsetvl result");
    VT_EQ(vt_trap_count, 0, "first vadd uses the new vtype");
    VT_EQ(VT_CSR_READ(vtype), 0x18, "committed e64 m1");
    VT_EQ(VT_CSR_READ(vstart), 0, "arithmetic clears vstart");
    return vt_finish("vec_vtype_handoff_test");
}
