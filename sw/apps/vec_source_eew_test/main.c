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


/* Trap entry records vector state without modifying it. */
#include "../vec_common/vec_test.h"

#ifndef VEC_VLEN
#define VEC_VLEN 256
#endif

#define OPV(f6, vm, vs2, vs1, f3, vd)                                                              \
    (((f6) << 26) | ((vm) << 25) | ((vs2) << 20) | ((vs1) << 15) | ((f3) << 12) | ((vd) << 7) |    \
     0x57)
#define EMIT(insn) __asm__ volatile(".word %0" : : "i"(insn) : "memory")

__attribute__((used)) volatile unsigned long source_trap_vs;

__asm__(".pushsection .text.source_trap,\"ax\"\n"
        ".balign 4\n.globl source_trap_entry\nsource_trap_entry:\n"
        "csrrw t6, mscratch, t6\n"
        "sd t0, 0(t6)\nsd t1, 8(t6)\nsd t2, 16(t6)\n"
        "csrr t0, mcause\nla t1, vt_trap_cause\nsd t0, 0(t1)\n"
        "csrr t0, mtval\nla t1, vt_trap_tval\nsd t0, 0(t1)\n"
        "csrr t0, vstart\nla t1, vt_trap_vstart\nsd t0, 0(t1)\n"
        "csrr t0, mstatus\nsrli t0, t0, 9\nandi t0, t0, 3\n"
        "la t1, source_trap_vs\nsd t0, 0(t1)\n"
        "la t1, vt_trap_count\nld t0, 0(t1)\naddi t0, t0, 1\nsd t0, 0(t1)\n"
        "csrr t0, mepc\nla t1, vt_trap_epc\nsd t0, 0(t1)\n"
        "addi t0, t0, 4\ncsrw mepc, t0\n"
        "ld t0, 0(t6)\nld t1, 8(t6)\nld t2, 16(t6)\n"
        "csrrw t6, mscratch, t6\nmret\n.popsection\n");
extern char source_trap_entry[];

static void prepare(unsigned long start)
{
    /* Immediate configuration keeps this independent of the register-form fix. */
    __asm__ volatile(".word 0x01807fd7" : : : "t6", "memory"); /* vsetvli t6,x0,e64,m1 */
    EMIT(OPV(0x17, 1, 0, 31, 3, 0)); /* all mask bits active; data value -1 */
    EMIT(OPV(0x17, 1, 0, 7, 3, 8));
    EMIT(OPV(0x17, 1, 0, 13, 3, 16));
    EMIT(OPV(0x17, 1, 0, 13, 3, 17));
    VT_CSR_WRITE(vstart, start);
    unsigned long status = VT_CSR_READ(mstatus);
    VT_CSR_WRITE(mstatus, (status & ~VT_MSTATUS_VS) | (2ul << 9));
    vt_trap_clear();
    source_trap_vs = ~0ul;
}

static void check_trap(unsigned long word, unsigned long start)
{
    /* Read both fields before a vector instruction or CSR write can change them. */
    unsigned long after_start = VT_CSR_READ(vstart);
    unsigned long after_vs = (VT_CSR_READ(mstatus) >> 9) & 3;
    VT_EQ(vt_trap_count, 1, "one illegal-instruction trap");
    VT_EQ(vt_trap_cause, 2, "illegal-instruction cause");
    VT_EQ(vt_trap_tval, word, "trap value is the instruction");
    VT_EQ(vt_trap_vstart, start, "trap entry preserves vstart");
    VT_EQ(after_start, start, "return preserves vstart");
    VT_EQ(source_trap_vs, 2, "trap entry preserves clean VS");
    VT_EQ(after_vs, 2, "return preserves clean VS");
    VT_CSR_WRITE(vstart, 0);
    EMIT(OPV(0x19, 1, 16, 17, 0, 1)); /* vmsne.vv v1,v16,v17 */
    register unsigned long mismatches __asm__("a0");
    __asm__ volatile(".word %1" : "=r"(mismatches) : "i"(OPV(0x10, 1, 1, 16, 2, 10)) : "memory");
    VT_EQ(mismatches, 0, "every destination element is unchanged");
}

int main(void)
{
    vt_enable_vector();
    vt_trap_install();
    VT_CSR_WRITE(mtvec, (unsigned long) source_trap_entry);
    VT_EQ(vt_vlenb() * 8, VEC_VLEN, "configured vector length");
    for (unsigned long start = 0; start <= 1; start++) {
        prepare(start);
        EMIT(OPV(0, 0, 0, 8, 0, 16));
        check_trap(OPV(0, 0, 0, 8, 0, 16), start);
        prepare(start);
        EMIT(OPV(0, 0, 8, 0, 0, 16));
        check_trap(OPV(0, 0, 8, 0, 0, 16), start);
    }
    return vt_finish("vec_source_eew_test");
}
