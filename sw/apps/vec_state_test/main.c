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
 *   - VS resets to Off and misa.V matches VEC_ADVERTISE;
 *   - with VS Off, every vector CSR access raises illegal-instruction;
 *   - with VS on, vlenb reads VLEN/8, vl reads 0 and vtype reads vill;
 *     vstart keeps log2(VLEN) bits; vxrm, vxsat and vcsr alias each other;
 *   - a vector CSR write sets VS to Dirty, and SD follows Dirty;
 *   - sstatus.VS is a view of mstatus.VS;
 *   - writes to vl, vtype and vlenb raise illegal-instruction;
 *   - vector loads and stores raise illegal-instruction with VS Off; with VS
 *     on and vill set, unit-stride and mask forms and misaligned whole-register
 *     groups raise illegal-instruction, while aligned whole-register accesses
 *     to low BRAM succeed, misaligned low-BRAM accesses raise address-
 *     misaligned faults, and unmapped addresses raise access faults.
 * Without the unit, VS reads zero and ignores writes, and every vector CSR
 * access and vector load or store raises illegal-instruction. In both
 * builds, a vector load on a mispredicted path, or a run of them ending in a
 * trap, leaves later scalar loads, stores and fences unaffected.
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
#ifndef VEC_ADVERTISE
#define VEC_ADVERTISE (VEC_VLEN != 0)
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

/* Sstvala: mtval holds the faulting instruction's bits, a compressed
 * instruction's 16 bits zero-extended. */
static unsigned long insn_bits_at(unsigned long pc)
{
    unsigned long lo = *(volatile unsigned short *) pc;
    if ((lo & 3u) != 3u)
        return lo;
    return lo | ((unsigned long) *(volatile unsigned short *) (pc + 2) << 16);
}

/* The trigger at `pc` raised illegal-instruction with mtval its instruction bits. */
static void check_illegal(const char *name, unsigned long pc)
{
    int ok = g_cause == 2u && g_epc == pc && g_tval == insn_bits_at(pc);
    check(name, ok, g_cause, 2u);
}

#if VEC_VLEN > 0
/* The trigger at `pc` raised `want_cause` with mtval `want_tval`. */
static void
check_fault(const char *name, unsigned long pc, unsigned long want_cause, unsigned long want_tval)
{
    int ok = g_cause == want_cause && g_epc == pc && g_tval == want_tval;
    check(name, ok, g_cause, want_cause);
}
#endif

/* Vector loads and stores, base register t5 (x30). */
#define VLE32_V1 ".word 0x020f6087"       /* vle32.v v1, (t5) */
#define VSE32_V1 ".word 0x020f60a7"       /* vse32.v v1, (t5) */
#define VLE8_V2_MASKED ".word 0x000f0107" /* vle8.v v2, (t5), v0.t */
#define VL1RE8_V1 ".word 0x028f0087"      /* vl1re8.v v1, (t5) */
#define VL2RE64_V1 ".word 0x228f7087"     /* vl2re64.v v1, (t5) (misaligned vd) */
#define VL2RE64_V2 ".word 0x228f7107"     /* vl2re64.v v2, (t5) */
#define VS1R_V1 ".word 0x028f00a7"        /* vs1r.v v1, (t5) */
#define VLM_V1 ".word 0x02bf0087"         /* vlm.v v1, (t5) */
#define VSM_V1 ".word 0x02bf00a7"         /* vsm.v v1, (t5) */

#define VBUF_WORDS 8
static volatile unsigned long g_vbuf[VBUF_WORDS] __attribute__((aligned(64)));

/* RUN_TRIGGER with t5 pointing at `base`. */
#define RUN_VMEM_AT(insn, base)                                                                    \
    ({                                                                                             \
        unsigned long trig__;                                                                      \
        reset_records();                                                                           \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n"                                                     \
                         "mv   t5, %1\n"                                                           \
                         "la   %0, 9f\n"                                                           \
                         "9: " insn "\n"                                                           \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         : "=&r"(trig__)                                                           \
                         : "r"(base)                                                               \
                         : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");                    \
        trig__;                                                                                    \
    })

/* RUN_TRIGGER with t5 pointing at g_vbuf. */
#define RUN_VMEM(insn) RUN_VMEM_AT(insn, g_vbuf)

static void fill_words(volatile unsigned long *buf)
{
    for (int i = 0; i < VBUF_WORDS; i++)
        buf[i] = 0x0101010101010101ul * (unsigned long) (i + 1);
}

static int words_intact(const volatile unsigned long *buf)
{
    for (int i = 0; i < VBUF_WORDS; i++)
        if (buf[i] != 0x0101010101010101ul * (unsigned long) (i + 1))
            return 0;
    return 1;
}

/* Every vector load and store form raises illegal-instruction, and no store
 * writes memory. */
static void check_vmem_illegal(const char *when)
{
    uart_printf("vector loads and stores illegal %s\n", when);
    fill_words(g_vbuf);
    check_illegal("vle32.v", RUN_VMEM(VLE32_V1));
    check_illegal("vse32.v", RUN_VMEM(VSE32_V1));
    check_illegal("vle8.v masked", RUN_VMEM(VLE8_V2_MASKED));
    check_illegal("vl1re8.v", RUN_VMEM(VL1RE8_V1));
    check_illegal("vl2re64.v", RUN_VMEM(VL2RE64_V2));
    check_illegal("vs1r.v", RUN_VMEM(VS1R_V1));
    check_illegal("vlm.v", RUN_VMEM(VLM_V1));
    check_illegal("vsm.v", RUN_VMEM(VSM_V1));
    /* A run of loads and stores: the first traps, the rest are discarded. */
    check_illegal(
        "vector run",
        RUN_VMEM(VLE32_V1 "\n" VSE32_V1 "\n" VLE32_V1 "\n" VS1R_V1 "\n" VLE32_V1 "\n" VSM_V1));
    check_eq("vector stores write nothing", words_intact(g_vbuf), 1);
}

#if VEC_VLEN > 0
/* With VS on and vill set, vtype-dependent forms and misaligned whole-register
 * groups raise illegal-instruction without modifying VS or memory. */
static void check_vmem_vill_illegal(void)
{
    uart_printf("vector loads and stores illegal with VS on, vill set\n");
    fill_words(g_vbuf);
    check_illegal("vle32.v (vill)", RUN_VMEM(VLE32_V1));
    check_illegal("vse32.v (vill)", RUN_VMEM(VSE32_V1));
    check_illegal("vle8.v masked (vill)", RUN_VMEM(VLE8_V2_MASKED));
    check_illegal("vl2re64.v v1 (unaligned)", RUN_VMEM(VL2RE64_V1));
    check_illegal("vlm.v (vill)", RUN_VMEM(VLM_V1));
    check_illegal("vsm.v (vill)", RUN_VMEM(VSM_V1));
    check_illegal(
        "vector run",
        RUN_VMEM(VLE32_V1 "\n" VSE32_V1 "\n" VLE32_V1 "\n" VS1R_V1 "\n" VLE32_V1 "\n" VSM_V1));
    check_eq("vector stores write nothing", words_intact(g_vbuf), 1);
}
#endif

/* A vector load behind a branch that resolves late (it waits for a load) and
 * is taken: the load is fetched on the wrong path and discarded. The scalar
 * loads, stores and fence after the branch must still complete. Returns the
 * sum of the values loaded. */
static unsigned long vmem_wrong_path(void)
{
    unsigned long sum = 0;
    g_vbuf[0] = 1;
    for (int i = 0; i < 16; i++) {
        unsigned long v;
        __asm__ volatile("mv   t5, %1\n"
                         "ld   t0, 0(t5)\n"
                         "bnez t0, 2f\n" VLE32_V1 "\n" VSE32_V1 "\n"
                         "2:\n"
                         "ld   %0, 8(t5)\n"
                         "sd   %0, 16(t5)\n"
                         "fence\n"
                         "ld   %0, 16(t5)\n"
                         : "=&r"(v)
                         : "r"(g_vbuf)
                         : "t0", "t5", "memory");
        sum += v;
    }
    return sum;
}

/* An indirect jump alternates between a vector load, which traps, and scalar
 * code with fences. Each time it goes to the scalar code its prediction is the
 * vector load, which is fetched on the wrong path and discarded by the jump's
 * recovery at commit. Returns the sum of the values the scalar code loads;
 * every fence must complete. */
static unsigned long vmem_jump_wrong_path(void)
{
    unsigned long sum;
    reset_records();
    __asm__ volatile("la   t0, 6f\n"
                     "csrw mscratch, t0\n"
                     "mv   t5, %1\n"
                     "li   %0, 0\n"
                     "la   a1, 8f\n"
                     "la   a2, 7f\n"
                     "li   a3, 12\n"
                     "2:\n"
                     "andi a4, a3, 1\n"
                     "mv   a5, a2\n"
                     "beqz a4, 3f\n"
                     "mv   a5, a1\n"
                     "3:\n"
                     "jalr x0, 0(a5)\n"
                     "8:\n" VLE32_V1 "\n"
                     "j    6f\n"
                     "7:\n"
                     "fence\n"
                     "ld   a4, 8(t5)\n"
                     "sd   a4, 16(t5)\n"
                     "fence\n"
                     "ld   a4, 16(t5)\n"
                     "add  %0, %0, a4\n"
                     "6:\n"
                     "addi a3, a3, -1\n"
                     "bnez a3, 2b\n"
                     : "=&r"(sum)
                     : "r"(g_vbuf)
                     : "t0", "t1", "t2", "t3", "t5", "a1", "a2", "a3", "a4", "a5", "memory");
    return sum;
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

#if VEC_VLEN > 0
/* Low BRAM is [0, 256 KiB) of the physical address map. */
#define LOW_BRAM_LIMIT 0x40000ul

/* Whole-register accesses to aligned low BRAM succeed, misaligned whole-
 * register accesses to low BRAM raise load address misaligned (cause 4), and
 * accesses to unmapped addresses past low BRAM raise load or store access
 * fault (cause 5 or 7) with mtval equal to the faulting address and dirty VS. */
static void check_vmem_bram_and_unmapped(void)
{
    volatile unsigned long buf[2 * VBUF_WORDS] __attribute__((aligned(64)));
    volatile unsigned long copy[VBUF_WORDS] __attribute__((aligned(64)));
    unsigned long buf_va = (unsigned long) buf;
    unsigned long unmapped = LOW_BRAM_LIMIT;
    unsigned long pc;
    check_eq("buffer in low BRAM", buf_va + sizeof(buf) <= LOW_BRAM_LIMIT, 1);
    fill_words(buf);
    for (int i = VBUF_WORDS; i < 2 * VBUF_WORDS; i++)
        buf[i] = 0x1010101010101010ul * (unsigned long) (i + 1);
    for (int i = 0; i < VBUF_WORDS; i++)
        copy[i] = 0ul;

    /* Aligned low-BRAM whole-register loads and stores succeed (followed by ecall cause 11). */
    set_vs(VS_CLEAN);
    pc = RUN_VMEM_AT(VL1RE8_V1, buf);
    check_eq("vl1re8.v (low BRAM) no trap", g_cause == 11u && g_epc == pc + 4, 1);
    check_eq("vl1re8.v load dirties VS", vs_field(), VS_DIRTY);
    set_vs(VS_CLEAN);
    pc = RUN_VMEM_AT(VS1R_V1, copy);
    check_eq("vs1r.v (low BRAM) no trap", g_cause == 11u && g_epc == pc + 4, 1);
    check_eq("vs1r.v keeps VS Clean", vs_field(), VS_CLEAN);
    check_eq("vs1r.v low BRAM data", copy[0], buf[0]);
    set_vs(VS_CLEAN);
    pc = RUN_VMEM_AT(VL2RE64_V2, buf);
    check_eq("vl2re64.v (low BRAM) no trap", g_cause == 11u && g_epc == pc + 4, 1);
    check_eq("vl2re64.v load dirties VS", vs_field(), VS_DIRTY);

    /* Misaligned EEW=64 access in low BRAM raises load address misaligned. */
    set_vs(VS_CLEAN);
    check_fault("vl2re64.v (BRAM misaligned)",
                RUN_VMEM_AT(VL2RE64_V2, (const char *) buf + 2),
                4u,
                buf_va + 2);
    check_eq("vl2re64.v misaligned dirties VS", vs_field(), VS_DIRTY);

    /* Unmapped physical address past low BRAM raises access faults. */
    set_vs(VS_CLEAN);
    check_fault("vl1re8.v (unmapped access fault)", RUN_VMEM_AT(VL1RE8_V1, unmapped), 5u, unmapped);
    check_eq("vl1re8.v fault dirties VS", vs_field(), VS_DIRTY);
    set_vs(VS_CLEAN);
    check_fault(
        "vl2re64.v (unmapped access fault)", RUN_VMEM_AT(VL2RE64_V2, unmapped), 5u, unmapped);
    check_eq("vl2re64.v fault dirties VS", vs_field(), VS_DIRTY);
    set_vs(VS_CLEAN);
    check_fault("vs1r.v (unmapped access fault)", RUN_VMEM_AT(VS1R_V1, unmapped), 7u, unmapped);
    check_eq("vs1r.v fault dirties VS", vs_field(), VS_DIRTY);
    check_eq("low BRAM buffer intact", words_intact(buf), 1);
}
#endif

int main(void)
{
    set_trap_handler(vec_trap_handler);
    uart_printf("vec_state_test VLEN=%u\n", (unsigned) VEC_VLEN);

    check_eq("misa.V matches build", csr_read(misa) & MISA_V, VEC_ADVERTISE ? MISA_V : 0);

#if VEC_VLEN == 0
    set_vs(VS_DIRTY);
    check_eq("VS reads zero", vs_field(), 0);
    check_eq("SD clear", csr_read(mstatus) & MSTATUS_SD, 0);
    check_all_illegal("without the unit");
    check_vmem_illegal("without the unit");
    fill_words(g_vbuf);
    check_eq("wrong-path vector load", vmem_wrong_path(), 16 * 0x0202020202020202ul);
    fill_words(g_vbuf);
    check_eq("jump-target vector load", vmem_jump_wrong_path(), 6 * 0x0202020202020202ul);
#else
    check_eq("VS resets Off", vs_field(), VS_OFF);
    check_all_illegal("with VS Off");
    check_vmem_illegal("with VS Off");
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

    /* With vill set, vtype-dependent forms, misaligned whole-register groups,
     * and wrong-path fetches leave VS Clean and memory untouched. */
    check_vmem_vill_illegal();
    fill_words(g_vbuf);
    check_eq("wrong-path vector load", vmem_wrong_path(), 16 * 0x0202020202020202ul);
    fill_words(g_vbuf);
    check_eq("jump-target vector load", vmem_jump_wrong_path(), 6 * 0x0202020202020202ul);
    check_eq("illegal and wrong-path vector ops leave VS", vs_field(), VS_CLEAN);

    check_vmem_bram_and_unmapped();

    set_vs(VS_OFF);
    check_all_illegal("with VS Off again");
#endif

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
