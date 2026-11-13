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
 * Vector state: mstatus.VS and the vector CSRs.
 *
 * Built with VEC_VLEN=<n> for a core with the vector unit (VECTOR=1,
 * VLEN=<n>), or with VEC_VLEN=0 for a core without it. With the unit:
 *   - VS resets to Off and misa.V stays clear (the build does not advertise V);
 *   - with VS Off, every vector CSR access raises illegal-instruction;
 *   - with VS on, vlenb reads VLEN/8, vl reads 0 and vtype reads vill;
 *     vstart keeps log2(VLEN) bits; vxrm, vxsat and vcsr alias each other;
 *   - a vector CSR write sets VS to Dirty, and SD follows Dirty;
 *   - sstatus.VS is a view of mstatus.VS;
 *   - writes to vl, vtype and vlenb raise illegal-instruction.
 * Without the unit, VS reads zero and ignores writes, and every vector CSR
 * access raises illegal-instruction.
 *
 * The mtvec handler records mcause, mepc and mtval for the first trap and
 * returns to the continuation in mscratch. An ecall follows each trigger, so
 * a trigger that does not trap records cause 11.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#ifndef VEC_VLEN
#define VEC_VLEN 0
#endif

#define MSTATUS_VS (3ul << 9)
#define MSTATUS_SD (1ul << 63)
#define MISA_V (1ul << 21)
#define VS_OFF 0ul
#define VS_INITIAL (1ul << 9)
#define VS_CLEAN (2ul << 9)
#define VS_DIRTY (3ul << 9)

static int g_ok = 1;
static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;

__attribute__((naked, aligned(4))) static void vec_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void reset_records(void)
{
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_tval = ~0ul;
}

/* Run one trigger instruction, labeled "9:", followed by the no-trap ecall.
 * Returns the trigger's address. */
#define RUN_TRIGGER(insn)                                                                          \
    ({                                                                                             \
        unsigned long trig__;                                                                      \
        reset_records();                                                                           \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n"                                                     \
                         "la   %0, 9f\n"                                                           \
                         "9: " insn "\n"                                                           \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         : "=&r"(trig__)                                                           \
                         :                                                                         \
                         : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");                    \
        trig__;                                                                                    \
    })

static void check(const char *name, int ok, unsigned long got, unsigned long want)
{
    if (!ok)
        g_ok = 0;
    uart_printf("%s %s got=%lx want=%lx\n", ok ? "[PASS]" : "[FAIL]", name, got, want);
}

static void check_eq(const char *name, unsigned long got, unsigned long want)
{
    check(name, got == want, got, want);
}

/* The trigger at `pc` raised illegal-instruction with mtval 0. */
static void check_illegal(const char *name, unsigned long pc)
{
    int ok = g_cause == 2u && g_epc == pc && g_tval == 0u;
    check(name, ok, g_cause, 2u);
}

static void set_vs(unsigned long vs)
{
    csr_clear(mstatus, MSTATUS_VS);
    csr_set(mstatus, vs);
}

static unsigned long vs_field(void)
{
    return csr_read(mstatus) & MSTATUS_VS;
}

/* Every vector CSR, read and written, raises illegal-instruction. */
static void check_all_illegal(const char *when)
{
    uart_printf("vector CSRs illegal %s\n", when);
    check_illegal("csrr vstart", RUN_TRIGGER("csrr t4, 0x008"));
    check_illegal("csrw vstart", RUN_TRIGGER("csrw 0x008, zero"));
    check_illegal("csrr vxsat", RUN_TRIGGER("csrr t4, 0x009"));
    check_illegal("csrw vxrm", RUN_TRIGGER("csrwi 0x00A, 1"));
    check_illegal("csrr vcsr", RUN_TRIGGER("csrr t4, 0x00F"));
    check_illegal("csrr vl", RUN_TRIGGER("csrr t4, 0xC20"));
    check_illegal("csrr vtype", RUN_TRIGGER("csrr t4, 0xC21"));
    check_illegal("csrr vlenb", RUN_TRIGGER("csrr t4, 0xC22"));
}

static unsigned long read_csr_008(void)
{
    unsigned long v;
    __asm__ volatile("csrr %0, 0x008" : "=r"(v));
    return v;
}

int main(void)
{
    set_trap_handler(vec_trap_handler);
    uart_printf("vec_state_test VLEN=%u\n", (unsigned) VEC_VLEN);

    check_eq("misa.V clear", csr_read(misa) & MISA_V, 0);

#if VEC_VLEN == 0
    set_vs(VS_DIRTY);
    check_eq("VS reads zero", vs_field(), 0);
    check_eq("SD clear", csr_read(mstatus) & MSTATUS_SD, 0);
    check_all_illegal("without the unit");
#else
    check_eq("VS resets Off", vs_field(), VS_OFF);
    check_all_illegal("with VS Off");
    /* An OP-V instruction and vsetvli are illegal in this build. */
    check_illegal("vsetvli", RUN_TRIGGER(".word 0x000372d7"));
    set_vs(VS_INITIAL);
    check_illegal("vadd.vv", RUN_TRIGGER(".word 0x022180d7"));
    check_eq("VS Initial", vs_field(), VS_INITIAL);
    check_eq("SD clear at Initial", csr_read(mstatus) & MSTATUS_SD, 0);

    unsigned long v;
    __asm__ volatile("csrr %0, 0xC22" : "=r"(v));
    check_eq("vlenb", v, VEC_VLEN / 8);
    __asm__ volatile("csrr %0, 0xC20" : "=r"(v));
    check_eq("vl resets 0", v, 0);
    __asm__ volatile("csrr %0, 0xC21" : "=r"(v));
    check_eq("vtype resets vill", v, 1ul << 63);
    check_eq("vstart resets 0", read_csr_008(), 0);
    check_eq("reads keep VS Initial", vs_field(), VS_INITIAL);

    __asm__ volatile("csrw 0x008, %0" ::"r"(~0ul));
    check_eq("vstart keeps log2(VLEN) bits", read_csr_008(), VEC_VLEN - 1);
    check_eq("vstart write sets Dirty", vs_field(), VS_DIRTY);
    check_eq("SD set at Dirty", csr_read(mstatus) & MSTATUS_SD, MSTATUS_SD);
    check_eq("sstatus.VS view", csr_read(sstatus) & MSTATUS_VS, VS_DIRTY);
    check_eq("sstatus.SD", csr_read(sstatus) & MSTATUS_SD, MSTATUS_SD);
    __asm__ volatile("csrw 0x008, zero");

    set_vs(VS_CLEAN);
    __asm__ volatile("csrwi 0x00A, 3" ::: "memory");
    __asm__ volatile("csrr %0, 0x00A" : "=r"(v));
    check_eq("vxrm", v, 3);
    check_eq("vxrm write sets Dirty", vs_field(), VS_DIRTY);
    __asm__ volatile("csrwi 0x009, 1" ::: "memory");
    __asm__ volatile("csrr %0, 0x009" : "=r"(v));
    check_eq("vxsat", v, 1);
    __asm__ volatile("csrr %0, 0x00F" : "=r"(v));
    check_eq("vcsr = {vxrm, vxsat}", v, 7);
    __asm__ volatile("csrwi 0x00F, 4" ::: "memory");
    __asm__ volatile("csrr %0, 0x00A" : "=r"(v));
    check_eq("vcsr writes vxrm", v, 2);
    __asm__ volatile("csrr %0, 0x009" : "=r"(v));
    check_eq("vcsr writes vxsat", v, 0);

    /* sstatus writes VS. */
    csr_clear(sstatus, MSTATUS_VS);
    csr_set(sstatus, VS_CLEAN);
    check_eq("sstatus writes VS", vs_field(), VS_CLEAN);
    check_eq("SD clear at Clean", csr_read(mstatus) & MSTATUS_SD, 0);

    /* The read-only vector CSRs reject writes. */
    check_illegal("csrw vl", RUN_TRIGGER("csrw 0xC20, zero"));
    check_illegal("csrw vtype", RUN_TRIGGER("csrw 0xC21, zero"));
    check_illegal("csrw vlenb", RUN_TRIGGER("csrw 0xC22, zero"));
    check_eq("rejected writes leave VS", vs_field(), VS_CLEAN);

    set_vs(VS_OFF);
    check_all_illegal("with VS Off again");
#endif

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
