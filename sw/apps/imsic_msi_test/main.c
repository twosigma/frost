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

/* MSI pages, access widths, byte orders, delivery, claims and Sv39 stores. */
#include "imsic.h"
#include "trap.h"
#include "uart.h"

static unsigned int checks, failures;
static volatile unsigned long m_count, s_count, m_claim, s_claim, bad_traps;
/* Absolute scratch addresses remain reachable from BRAM and DDR code. */
static volatile uint64_t *const root = (volatile uint64_t *) 0x81000000ul;
static volatile uint64_t *const middle = (volatile uint64_t *) 0x81001000ul;
static void check(const char *name, unsigned long got, unsigned long want)
{
    checks++;
    if (got != want) {
        failures++;
        uart_printf("[FAIL] %s got=%lx want=%lx\n", name, got, want);
    }
}
static unsigned long top_wait(unsigned int level, unsigned long want)
{
    for (unsigned int n = 0; n < 2000; n++) {
        unsigned long top = imsic_top(level);
        if (top == want)
            return top;
    }
    return imsic_top(level);
}
static unsigned long pending_wait(unsigned long mask, unsigned long want)
{
    for (unsigned int n = 0; n < 2000; n++)
        if ((csr_read(mip) & mask) == want)
            return want;
    return csr_read(mip) & mask;
}
__attribute__((interrupt("machine"), aligned(4))) static void m_handler(void)
{
    unsigned long cause = csr_read(mcause);
    if (cause == ((1ul << 63) | 11)) {
        m_claim = imsic_claim(0);
        m_count++;
    } else if (cause == 9) {
        csr_write(mepc, csr_read(mscratch));
        csr_set(mstatus, 0x1800ul);
    } else {
        bad_traps++;
        csr_write(mepc, csr_read(mepc) + 4);
    }
}
__attribute__((interrupt("supervisor"), aligned(4))) static void s_handler(void)
{
    if (csr_read(scause) != ((1ul << 63) | 9))
        bad_traps++;
    s_claim = imsic_claim(1);
    s_count++;
}
static void s_body(void)
{
    csr_set(sie, 1ul << 9);
    csr_set(sstatus, 2ul);
    imsic_send(1, 0, 11);
    for (unsigned int n = 0; n < 20000 && !s_count; n++)
        __asm__ volatile("nop");
    csr_clear(sstatus, 2ul);
    csr_clear(sie, 1ul << 9);
}
static void run_s(void (*fn)(void))
{
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n li t0, 0x1888\n csrc mstatus, t0\n"
                     "li t0, 0x800\n csrs mstatus, t0\n la t0, 2f\n csrw mepc, t0\n mret\n"
                     "2: jalr ra, %0, 0\n ecall\n j .\n 1:\n"
                     :
                     : "r"(fn)
                     : "ra",
                       "t0",
                       "t1",
                       "t2",
                       "t3",
                       "t4",
                       "t5",
                       "t6",
                       "a0",
                       "a1",
                       "a2",
                       "a3",
                       "a4",
                       "a5",
                       "a6",
                       "a7",
                       "memory");
}
int main(void)
{
    csr_write(mie, 0ul);
    csr_write(mtvec, (unsigned long) m_handler);
    csr_write(stvec, (unsigned long) s_handler);
    csr_write(mideleg, 0ul);
    for (unsigned int level = 0; level < 2; level++) {
        uintptr_t base = level ? IMSIC_S_BASE : IMSIC_M_BASE;
        imsic_write(level, IMSIC_EIE0, ~1ul);
        imsic_write(level, IMSIC_EIDELIVERY, 0);
        for (uint32_t id = 1; id <= IMSIC_NUM_IDS; id++) {
            unsigned long expected = ((unsigned long) id << 16) | id;
            imsic_send(level, 0, id);
            check("little endian store", top_wait(level, expected), expected);
            check("little endian claim", imsic_claim(level), expected);
            *(volatile uint32_t *) (base + 4) = __builtin_bswap32(id);
            check("big endian store", top_wait(level, expected), expected);
            check("big endian claim", imsic_claim(level), expected);
        }
        *(volatile uint8_t *) base = 7;
        *(volatile uint8_t *) (base + 4) = 7;
        *(volatile uint8_t *) (base + 7) = 7;
        *(volatile uint16_t *) base = 7;
        *(volatile uint16_t *) (base + 4) = 7;
        *(volatile uint16_t *) (base + 6) = 0x0700;
        *(volatile uint64_t *) base = 0x0700000000000007ul;
        imsic_send(level, 0, 0);
        imsic_send(level, 0, 64);
        imsic_send(level, 0, ~0u);
        *(volatile uint32_t *) (base + 8) = 7;
        *(volatile uint32_t *) (base + 0x1000) = 7;
        check("ignored stores", imsic_read(level, IMSIC_EIP0), 0);
        imsic_send(level, 0, 13);
        check("pending before reads", top_wait(level, 0xd000d), 0xd000d);
        check("word read zero", *(volatile uint32_t *) base, 0);
        check("BE word read zero", *(volatile uint32_t *) (base + 4), 0);
        check("byte read zero", *(volatile uint8_t *) base, 0);
        check("half read zero", *(volatile uint16_t *) (base + 4), 0);
        check("double read zero", *(volatile uint64_t *) base, 0);
        check("unused page read zero", *(volatile uint32_t *) (base + 0x1000), 0);
        check("loads never claim", imsic_top(level), 0xd000d);
        unsigned long mask = 1ul << (level ? 9 : 11);
        check("delivery disabled", pending_wait(mask, 0), 0);
        imsic_write(level, IMSIC_EIDELIVERY, 1);
        check("delivery enabled", pending_wait(mask, mask), mask);
        imsic_write(level, IMSIC_EITHRESHOLD, 13);
        check("threshold hides equal", imsic_top(level), 0);
        check("threshold masks line", pending_wait(mask, 0), 0);
        imsic_write(level, IMSIC_EITHRESHOLD, 14);
        check("threshold reveals", imsic_top(level), 0xd000d);
        check("claim threshold winner", imsic_claim(level), 0xd000d);
        imsic_write(level, IMSIC_EITHRESHOLD, 0);
    }
    /* A translated store must pass the exact device PMA, including S pages. */
    for (unsigned int n = 0; n < 512; n++)
        root[n] = middle[n] = 0;
    root[1] = (((uintptr_t) middle >> 12) << 10) | 1;
    middle[256] = ((IMSIC_M_BASE >> 12) << 10) | 0xc7;
    __asm__ volatile("fence rw, rw" ::: "memory");
    csr_write(satp, (8ul << 60) | ((uintptr_t) root >> 12));
    __asm__ volatile("sfence.vma" ::: "memory");
    for (unsigned int level = 0; level < 2; level++) {
        unsigned long zero;
        uintptr_t va = 0x60000000ul + (level ? 0x100000 : 0);
        csr_clear(mstatus, 0x1800ul);
        csr_set(mstatus, 0x800ul);
        __asm__ volatile("csrs mstatus, %3\n sw %2, 0(%1)\n lw %0, 0(%1)\n csrc mstatus, %3"
                         : "=&r"(zero)
                         : "r"(va), "r"(17ul), "r"(1ul << 17)
                         : "memory");
        check("translated zero read", zero, 0);
        check("translated MSI", top_wait(level, 0x110011), 0x110011);
        check("translated claim", imsic_claim(level), 0x110011);
    }
    csr_write(satp, 0ul);
    __asm__ volatile("sfence.vma" ::: "memory");
    imsic_send(0, 0, 9);
    wfi();
    check("WFI wakes on masked MSI", imsic_claim(0), 0x90009);
    csr_set(mie, 1ul << 11);
    csr_set(mstatus, 8ul);
    imsic_send(0, 0, 10);
    for (unsigned int n = 0; n < 20000 && !m_count; n++)
        __asm__ volatile("nop");
    csr_clear(mstatus, 8ul);
    csr_write(mie, 0ul);
    check("machine trap count", m_count, 1);
    check("machine trap claim", m_claim, 0xa000a);
    csr_write(mideleg, 1ul << 9);
    run_s(s_body);
    check("supervisor trap count", s_count, 1);
    check("supervisor trap claim", s_claim, 0xb000b);
    check("no unexpected traps", bad_traps, 0);
    uart_printf("IMSIC MSI checks: %u passed, %u failed\n", checks - failures, failures);
    uart_puts(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
