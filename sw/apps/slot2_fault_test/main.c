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
 * Fetch fault on the second instruction of a fetch pair.
 *
 * IF pairs a good slot-1 instruction with a slot-2 instruction taken from
 * the next word. When that word's fetch faults, slot 2 must still reach
 * dispatch and trap at its own PC, even when its bytes happen to encode a
 * NOP (0x00000013), which decode otherwise drops. Each case runs, in S-mode,
 * an instruction at the end of a code page whose next virtual page is mapped
 * without X, so the partner's fetch raises an instruction page fault (12):
 *
 *   A. A 32-bit slot 1 in the page's last word; slot 2 is the next page's
 *      word 0: mepc = mtval = the next page.
 *   B. A compressed slot 1 at 0xFFC; slot 2 starts at 0xFFE and straddles
 *      into the next page: mepc = the next page - 2, mtval = the next page.
 *
 * Slot 1 must retire (a1 is set) in both. A faulting fetch reads the
 * physical address equal to the faulting virtual address. In the low-BRAM
 * build each next virtual page is chosen to alias, within the 256 KiB BRAM,
 * a page whose bytes make the faulting instruction a NOP (s2f_nops for A,
 * s2f_zeros after the 0x0013 low half for B). Other builds fetch other bytes
 * there; the checks still hold. Page tables live in cached DDR.
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

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
static volatile unsigned long g_a1;

extern char s2f_code_native[], s2f_code_rvc[], s2f_nops[], s2f_zeros[];

/* Tables in cached DDR, clear of any program image. VA window: vpn2 = 0,
 * vpn1 = 3 (0x0060_0000..0x007F_FFFF), whose base is a multiple of the
 * 256 KiB BRAM, so VA 0x0060_0000 + x aliases BRAM offset x. */
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define VA_WINDOW 0x00600000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

#define MSTATUS_MPP_MASK 0x1800ul
#define MPP_S 0x0800ul
#define REPEATS 4

/* M-mode bounce handler: record mcause/mepc/mtval and a1 for the case's first
 * trap, then return to the mscratch continuation in M-mode. */
__attribute__((naked, aligned(4))) static void s2f_trap_handler(void)
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
                     "la   t1, g_a1\n"
                     "sd   a1, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* Enter S-mode at target with a1 = 0; the case ends in a trap to M. */
static void run_at(unsigned long target)
{
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_tval = ~0ul;
    g_a1 = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, %2\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %1\n"
                     "csrw mepc, %0\n"
                     "li   a1, 0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(target), "r"(MPP_S), "i"(MSTATUS_MPP_MASK)
                     : "t0", "t1", "t2", "t3", "a1", "memory");
}

/* Map the code page just below the faulting page, which aliases filler. */
static unsigned long map_case(const char *code, const char *filler)
{
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    unsigned long idx = ((unsigned long) filler >> 12) & 0x1FF;
    if (idx == 0)
        idx = 1;
    for (int i = 0; i < 512; i++)
        l0[i] = 0;
    l0[idx - 1] = PTE_PPN(code) | PTE_V | PTE_X | PTE_A;
    l0[idx] = PTE_PPN(filler) | PTE_V | PTE_R | PTE_A; /* no X */
    __asm__ volatile("sfence.vma" ::: "memory");
    return VA_WINDOW + (idx << 12);
}

static int
report(const char *name, unsigned long want_epc, unsigned long want_tval, unsigned long want_a1)
{
    int ok = g_cause == 12u && g_epc == want_epc && g_tval == want_tval && g_a1 == want_a1;
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" epc=");
    uart_hex(g_epc);
    uart_puts(" tval=");
    uart_hex(g_tval);
    uart_puts(" a1=");
    uart_hex(g_a1);
    uart_puts("\r\n");
    return ok;
}

int main(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    int all_ok = 1;

    uart_puts("\r\n=== Slot-2 fetch-fault test ===\r\n");
    set_trap_handler(&s2f_trap_handler);

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[(VA_WINDOW >> 21) & 0x1FF] = PTE_PPN(PT_L0) | PTE_V;
    __asm__ volatile("sfence.vma" ::: "memory");
    __asm__ volatile("csrw satp, %0" : : "r"(SATP_SV39 | (PT_ROOT >> 12)));

    /* A: 32-bit slot 1 in the last word; slot 2 is the next page's word 0. */
    unsigned long next = map_case(s2f_code_native, s2f_nops);
    for (int rep = 0; rep < REPEATS; rep++) {
        run_at(next - 4);
        all_ok &= report("A native slot 1, slot-2 fault", next, next, 0xA7);
    }

    /* B: compressed slot 1; slot 2 straddles into the faulting page. */
    next = map_case(s2f_code_rvc, s2f_zeros);
    for (int rep = 0; rep < REPEATS; rep++) {
        run_at(next - 4);
        all_ok &= report("B compressed slot 1, straddling slot-2 fault", next - 2, next, 7);
    }

    __asm__ volatile("csrw satp, zero\n"
                     "sfence.vma" ::
                         : "memory");
    uart_puts(all_ok ? "<<PASS>>\r\n" : "<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
