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
 * A/D-transition fault test (Phase 3, bug-2 triage). FROST's walker is
 * read-only (plan D7): hardware never sets PTE A/D, so software must take
 * a page fault and set them itself. The riscv-tests demand pager relies on
 * exactly one sequence that no existing directed test covers:
 *
 *   1. install PTE with A=1,D=1 and sfence          (page usable by the kernel)
 *   2. kernel touches the page                       (fills the DTLB, D=1)
 *   3. rewrite the SAME PTE to A=0,D=0 and sfence    (hand the page to user)
 *   4. the next store MUST take a store page fault so software can set D
 *
 * If step 3's rewrite is not visible to the translation path — a stale DTLB
 * entry, or a walker refill that reads the pre-rewrite PTE from L2/DDR
 * because the sfence's writeback-all did not publish it — then step 4's
 * store silently succeeds against a D=0 page. The page then diverges from
 * its backing store with D never set, which is precisely the env_v evict()
 * assertion (`user_llpt[...] & PTE_D`) that rv64ui-v-ld / -lw fail on.
 *
 * Cases (all in an MPRV S-window over Sv39, the vm_test mechanism):
 *   A. baseline: store then load through an A=1,D=1 page.
 *   B. clear D (keep A), sfence, store -> MUST fault 15.
 *   C. set D again, sfence, store -> succeeds; the value lands.
 *   D. clear A and D, sfence, load -> MUST fault 13.
 *   E. set A (D still 0), sfence, load -> succeeds; store -> MUST fault 15.
 *   F. env_v's exact shape: A=1,D=1 -> touch -> rewrite to A=0,D=0 with an
 *      ADDRESS-SPECIFIC sfence.vma, then store -> MUST fault 15.
 *   G. after F's fault, software sets D, sfence, store -> succeeds and the
 *      page content matches what was written (the divergence the pager's
 *      memcmp would otherwise see).
 *   H. the demand copy itself: 4 KiB of translated stores into a fresh
 *      frame, then a physical word-by-word compare against the backing —
 *      the other way the assert can fire (a store lost in the L1D
 *      write-allocate merge path).
 * Self-checks over UART (<<PASS>> / <<FAIL>>).
 */

#include <stdint.h>

#include "trap.h"

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

#define LREG "ld"
#define SREG "sd"

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
/* Value readback channel: the case-ending ecall traps, and the handler
 * overwrites g_tval with mtval — in-window loads must land here instead. */
static volatile unsigned long g_val;

/* M-mode bounce handler (vm_test shape): record the first trap of each
 * case, force MPP=M, resume at the mscratch continuation. */
__attribute__((naked, aligned(4))) static void ad_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n" LREG " t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n" SREG " t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

#define RUN_CASE(body_asm, ...)                                                                    \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_epc = ~0ul;                                                                              \
        g_tval = ~0ul;                                                                             \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n" body_asm "\n"                                       \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         :                                                                         \
                         : __VA_ARGS__                                                             \
                         : "t0", "t1", "t2", "t3", "t4", "memory");                                \
        __asm__ volatile("li t0, 0x20000\n csrc mstatus, t0" ::: "t0");                            \
    } while (0)

/* MPRV S-window (translation applies to data accesses at S) */
#define WIN_S                                                                                      \
    "li   t4, 0x1800\n"                                                                            \
    "csrc mstatus, t4\n"                                                                           \
    "li   t4, 0x0800\n"                                                                            \
    "csrs mstatus, t4\n"                                                                           \
    "li   t4, 0x20000\n"                                                                           \
    "csrs mstatus, t4\n"
#define WIN_END                                                                                    \
    "li   t4, 0x20000\n"                                                                           \
    "csrc mstatus, t4\n"

#define PT_ROOT 0x81000000ul
#define PT_L1 0x81002000ul
#define PT_L0 0x81003000ul
#define FRAME0 0x81100000ul
#define FRAME1 0x81101000ul
#define VA0 0x00400000ul
#define VA1 0x00401000ul
#define VA2 0x00402000ul
#define FRAME2 0x81102000ul
#define BACKING 0x81300000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

#define CAUSE_LOAD_PAGE_FAULT 13ul
#define CAUSE_STORE_PAGE_FAULT 15ul
#define CAUSE_ECALL_M 11ul

static volatile unsigned long *const l0 = (volatile unsigned long *) PT_L0;

static inline void sfence_all(void)
{
    __asm__ volatile("sfence.vma" ::: "memory");
}

static inline void sfence_va(unsigned long va)
{
    __asm__ volatile("sfence.vma %0" : : "r"(va) : "memory");
}

static void set_pte(int idx, unsigned long frame, unsigned long flags, int addr_specific)
{
    l0[idx] = PTE_PPN(frame) | PTE_V | PTE_R | PTE_W | PTE_X | flags;
    if (addr_specific)
        sfence_va(VA0 + ((unsigned long) idx << 12));
    else
        sfence_all();
}

static void build_tables(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    /* VA 0x0040_0000: vpn2=0, vpn1=2, vpn0=0/1 */
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;
    l0[0] = PTE_PPN(FRAME0) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l0[1] = PTE_PPN(FRAME1) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    /* Identity 1 GiB leaf at vpn2=2 so the M-mode code/data keep working
     * inside the MPRV window (VA 0x8000_0000 = PA). */
    root[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
}

static int report(const char *name, unsigned long got, unsigned long want)
{
    int ok = (got == want);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return ok;
}

int main(void)
{
    int ok = 1;
    unsigned long val = 0;

    uart_puts("\r\n=== A/D transition fault test ===\r\n");
    set_trap_handler(&ad_trap_handler);
    build_tables();
    __asm__ volatile("csrw satp, %0" : : "r"(SATP_SV39 | (PT_ROOT >> 12)) : "memory");
    sfence_all();

    /* A: baseline store+load through an A=1,D=1 page. */
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" LREG " t3, 0(%0)\n" WIN_END "la t1, g_val\n" SREG
                        " t3, 0(t1)\n",
             "r"(VA0),
             "r"(0x1122334455667788ul));
    ok &= report("A base-store-cause", g_cause, CAUSE_ECALL_M);
    ok &= report("A base-value", g_val, 0x1122334455667788ul);

    /* B: clear D (keep A), sfence, store -> store page fault. */
    set_pte(0, FRAME0, PTE_A, 0);
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" WIN_END, "r"(VA0), "r"(0xdeadbeeful));
    ok &= report("B store-D0-cause", g_cause, CAUSE_STORE_PAGE_FAULT);
    ok &= report("B store-D0-tval", g_tval, VA0);

    /* C: software sets D (as a pager would), sfence, store succeeds. */
    set_pte(0, FRAME0, PTE_A | PTE_D, 0);
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" LREG " t3, 0(%0)\n" WIN_END "la t1, g_val\n" SREG
                        " t3, 0(t1)\n",
             "r"(VA0),
             "r"(0x00c0ffeeul));
    ok &= report("C store-after-setD-cause", g_cause, CAUSE_ECALL_M);
    ok &= report("C store-after-setD-value", g_val, 0x00c0ffeeul);

    /* D: clear A and D, sfence, load -> load page fault. */
    set_pte(0, FRAME0, 0, 0);
    RUN_CASE(WIN_S LREG " t3, 0(%0)\n" WIN_END, "r"(VA0));
    ok &= report("D load-A0-cause", g_cause, CAUSE_LOAD_PAGE_FAULT);
    ok &= report("D load-A0-tval", g_tval, VA0);

    /* E: set A only; load succeeds, store still faults. */
    set_pte(0, FRAME0, PTE_A, 0);
    RUN_CASE(WIN_S LREG " t3, 0(%0)\n" WIN_END "la t1, g_val\n" SREG " t3, 0(t1)\n", "r"(VA0));
    ok &= report("E load-A1-cause", g_cause, CAUSE_ECALL_M);
    ok &= report("E load-A1-value", g_val, 0x00c0ffeeul);
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" WIN_END, "r"(VA0), "r"(0x5a5a5a5aul));
    ok &= report("E store-D0-cause", g_cause, CAUSE_STORE_PAGE_FAULT);

    /* F: the pager's exact shape on a fresh page — A=1,D=1, kernel touch,
     * rewrite to A=0,D=0 with an ADDRESS-SPECIFIC sfence, then store. */
    set_pte(1, FRAME1, PTE_A | PTE_D, 1);
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" WIN_END, "r"(VA1), "r"(0x0123456789abcdeful));
    ok &= report("F kernel-touch-cause", g_cause, CAUSE_ECALL_M);
    set_pte(1, FRAME1, 0, 1); /* hand to user: A=0, D=0, address sfence */
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" WIN_END, "r"(VA1), "r"(0xbadbadbadul));
    ok &= report("F user-store-cause", g_cause, CAUSE_STORE_PAGE_FAULT);
    ok &= report("F user-store-tval", g_tval, VA1);

    /* G: the pager sets A|D and retries; the store lands and reads back —
     * and the frame still holds the kernel's value everywhere else. */
    set_pte(1, FRAME1, PTE_A | PTE_D, 1);
    RUN_CASE(WIN_S SREG " %1, 0(%0)\n" LREG " t3, 0(%0)\n" WIN_END "la t1, g_val\n" SREG
                        " t3, 0(t1)\n",
             "r"(VA1),
             "r"(0xbadbadbadul));
    ok &= report("G retry-cause", g_cause, CAUSE_ECALL_M);
    ok &= report("G retry-value", g_val, 0xbadbadbadul);

    /* The physical frame must agree with what the translated stores wrote
     * (the divergence check the pager's memcmp performs). */
    val = *(volatile unsigned long *) FRAME1;
    ok &= report("G frame-matches", val, 0xbadbadbadul);
    val = *(volatile unsigned long *) FRAME0;
    ok &= report("G frame0-matches", val, 0x00c0ffeeul);

    /* H: the pager's demand copy itself — 4 KiB of translated stores into a
     * fresh frame, then a physical compare against the backing. This is the
     * other way the evict() assert can fire: if the copy is lossy (a store
     * dropped in the L1D write-allocate merge path), the frame diverges
     * from the backing with D never set, exactly as observed. */
    {
        volatile unsigned long *backing = (volatile unsigned long *) BACKING;
        volatile unsigned long *frame = (volatile unsigned long *) FRAME2;
        unsigned long first_bad = ~0ul, bad_count = 0;

        for (unsigned long i = 0; i < 512; i++) {
            backing[i] = 0xA5A5000000000000ul | i;
            frame[i] = 0;
        }
        set_pte(2, FRAME2, PTE_A | PTE_D, 0);

        /* Translated 4 KiB copy, kernel-style (the window covers both the
         * VA page and the identity-mapped backing). */
        RUN_CASE(WIN_S "mv   t1, %0\n"
                       "mv   t2, %1\n"
                       "li   t3, 512\n"
                       "3:\n" LREG " t0, 0(t2)\n" SREG " t0, 0(t1)\n"
                       "addi t1, t1, 8\n"
                       "addi t2, t2, 8\n"
                       "addi t3, t3, -1\n"
                       "bnez t3, 3b\n" WIN_END,
                 "r"(VA2),
                 "r"(BACKING));
        ok &= report("H copy-cause", g_cause, CAUSE_ECALL_M);

        for (unsigned long i = 0; i < 512; i++) {
            if (frame[i] != (0xA5A5000000000000ul | i)) {
                if (first_bad == ~0ul)
                    first_bad = i;
                bad_count++;
            }
        }
        ok &= report("H copy-mismatch-count", bad_count, 0);
        if (bad_count) {
            uart_puts("       first bad word idx=");
            uart_hex(first_bad);
            uart_puts(" got=");
            uart_hex(frame[first_bad]);
            uart_puts(" want=");
            uart_hex(0xA5A5000000000000ul | first_bad);
            uart_puts("\r\n");
        }
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
