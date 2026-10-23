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

/* Indirect CSR legality, write intent, aliases and major-interrupt priority. */
#include "imsic.h"
#include "trap.h"
#include "uart.h"

static volatile unsigned long illegal_count, unexpected_count;
static unsigned int checks, failures;
static void check(const char *name, unsigned long got, unsigned long want)
{
    checks++;
    if (got != want) {
        failures++;
        uart_printf("[FAIL] %s: got=%lx want=%lx\n", name, got, want);
    }
}

/* Illegal CSR instructions are four bytes. ECALL returns a privilege probe
 * to its M-mode continuation. All probes preserve the rest of the registers. */
__attribute__((naked, aligned(4))) static void handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n sd t0, 0(sp)\n sd t1, 8(sp)\n sd t2, 16(sp)\n"
                     "csrr t0, mcause\n li t1, 2\n bne t0, t1, 2f\n"
                     "la t1, illegal_count\n ld t2, 0(t1)\n addi t2, t2, 1\n sd t2, 0(t1)\n"
                     "csrr t0, mepc\n addi t0, t0, 4\n csrw mepc, t0\n j 4f\n"
                     "2: li t1, 8\n beq t0, t1, 3f\n li t1, 9\n beq t0, t1, 3f\n"
                     "la t1, unexpected_count\n ld t2, 0(t1)\n addi t2, t2, 1\n sd t2, 0(t1)\n"
                     "3: csrr t0, mscratch\n csrw mepc, t0\n li t0, 0x1800\n csrs mstatus, t0\n"
                     "4: ld t0, 0(sp)\n ld t1, 8(sp)\n ld t2, 16(sp)\n addi sp, sp, 32\n mret\n");
}
static void at_priv(void (*fn)(void), unsigned long mpp)
{
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n li t0, 0x1888\n csrc mstatus, t0\n"
                     "csrs mstatus, %1\n csrw mepc, %0\n mret\n 1:\n"
                     :
                     : "r"(fn), "r"(mpp)
                     : "t0", "t1", "t2", "memory");
}
__attribute__((naked)) static void s_indirect(void)
{
    __asm__ volatile("csrr t0, 0x151\n ecall\n");
}
__attribute__((naked)) static void lower_csrs(void)
{
    __asm__ volatile("csrr t0, 0x350\n csrr t0, 0x351\n csrr t0, 0x35c\n"
                     "csrr t0, 0xfb0\n csrr t0, 0x308\n csrr t0, 0x309\n"
                     "csrr t0, 0x150\n csrr t0, 0x151\n csrr t0, 0x15c\n"
                     "csrr t0, 0xdb0\n ecall\n");
}
static int legal(unsigned int sel)
{
    return (sel >= 0x30 && sel < 0x40 && !(sel & 1)) || (sel >= 0x70 && sel < 0x80) ||
           (sel >= 0x80 && sel < 0x100 && !(sel & 1));
}
static unsigned long expected_top(unsigned long bits)
{
    const unsigned int order[] = {11, 3, 7, 9, 1, 5};
    for (unsigned int n = 0; n < 6; n++)
        if (bits & (1ul << order[n]))
            return (order[n] << 16) | 1;
    return 0;
}
static unsigned long spread(unsigned int bits)
{
    const unsigned int ids[] = {11, 3, 7, 9, 1, 5};
    unsigned long value = 0;
    for (unsigned int n = 0; n < 6; n++)
        if (bits & (1u << n))
            value |= 1ul << ids[n];
    return value;
}
int main(void)
{
    csr_write(mie, 0ul);
    csr_write(mtvec, (unsigned long) handler);
    csr_write(medeleg, 0ul);
    csr_write(mideleg, 0ul);
    for (unsigned int level = 0; level < 2; level++) {
        check("delivery reset", imsic_read(level, IMSIC_EIDELIVERY), IMSIC_APLIC_DELIVERY);
        for (unsigned int sel = 0; sel < 512; sel++) {
            imsic_select(level, sel);
            check("select readback", level ? csr_read(0x150) : csr_read(0x350), sel);
            unsigned long before = illegal_count;
            unsigned long value = level ? csr_read(0x151) : csr_read(0x351);
            check("indirect read legality", illegal_count - before, !legal(sel));
            if (legal(sel) && sel != IMSIC_EIDELIVERY)
                check("reset indirect value", value, 0);
            before = illegal_count;
            if (level)
                csr_write(0x151, 0ul);
            else
                csr_write(0x351, 0ul);
            check("indirect write legality", illegal_count - before, !legal(sel));
            if (level) {
                before = illegal_count;
                at_priv(s_indirect, 0x800);
                check("S indirect legality", illegal_count - before, !legal(sel));
            }
        }
        imsic_select(level, ~0ul);
        check("select saturates", level ? csr_read(0x150) : csr_read(0x350), 0x1ff);
        imsic_select(level, 0x200);
        check("select above range", level ? csr_read(0x150) : csr_read(0x350), 0x1ff);
        imsic_write(level, IMSIC_EIE0, ~0ul);
        check("enable identity zero", imsic_read(level, IMSIC_EIE0), ~1ul);
        imsic_write(level, IMSIC_EIP0, 0x28);
        check("first identity", imsic_top(level), 0x30003);
        check("read does not claim", imsic_top(level), 0x30003);
        unsigned long value;
        if (level)
            __asm__ volatile("csrrc %0, 0x15c, x0" : "=r"(value));
        else
            __asm__ volatile("csrrc %0, 0x35c, x0" : "=r"(value));
        check("clear x0 read", value, 0x30003);
        check("clear x0 retains", imsic_top(level), 0x30003);
        if (level)
            __asm__ volatile("li t0, 0\n csrrs %0, 0x15c, t0" : "=r"(value) : : "t0");
        else
            __asm__ volatile("li t0, 0\n csrrs %0, 0x35c, t0" : "=r"(value) : : "t0");
        check("zero-valued register claims", value, 0x30003);
        check("next identity", imsic_top(level), 0x50005);
        check("swap claims", imsic_claim(level), 0x50005);
        check("claimed empty", imsic_top(level), 0);
        imsic_write(level, IMSIC_EIP0, 0x8);
        imsic_select(level, IMSIC_EIP0);
        if (level) {
            csr_set(0x151, 0x20ul);
            csr_clear(0x151, 0x8ul);
        } else {
            csr_set(0x351, 0x20ul);
            csr_clear(0x351, 0x8ul);
        }
        check("pending RMW", imsic_read(level, IMSIC_EIP0), 0x20);
        imsic_write(level, IMSIC_EITHRESHOLD, 5);
        check("threshold excludes equal", imsic_top(level), 0);
        imsic_write(level, IMSIC_EITHRESHOLD, 6);
        check("threshold allows lower", imsic_top(level), 0x50005);
        imsic_write(level, IMSIC_EITHRESHOLD, 0);
        imsic_write(level, IMSIC_EIDELIVERY, 1);
        for (unsigned int sel = 0x30; sel < 0x40; sel += 2) {
            imsic_write(level, sel, ~0ul);
            check("major priorities zero", imsic_read(level, sel), 0);
        }
        check("word above implementation", imsic_read(level, 0x82), 0);
        imsic_write(level, 0x82, ~0ul);
        check("unimplemented word ignores write", imsic_read(level, 0x82), 0);
    }
    /* All six major classes pending. Trap delivery stays globally disabled. */
    *(volatile uint64_t *) 0x40014000ul = 0;
    *(volatile uint32_t *) 0x40010000ul = 1;
    csr_write(mip, 0x222ul);
    for (unsigned int en = 0; en < 64; en++) {
        unsigned long enables = spread(en);
        csr_write(mie, enables);
        for (unsigned int d = 0; d < 8; d++) {
            unsigned long delegation =
                ((d & 1) ? 2ul : 0) | ((d & 2) ? 32ul : 0) | ((d & 4) ? 512ul : 0);
            csr_write(mideleg, delegation);
            check("mtopi priority", csr_read(0xfb0), expected_top(enables & ~delegation));
            check("stopi priority", csr_read(0xdb0), expected_top(enables & delegation));
        }
    }
    csr_write(mie, 0ul);
    *(volatile uint64_t *) 0x40014000ul = ~0ul;
    *(volatile uint32_t *) 0x40010000ul = 0;
    csr_write(0x308, ~0ul);
    check("mvien zero", csr_read(0x308), 0);
    csr_write(0x309, 0x222ul);
    check("mvip software bits", csr_read(0x309), 0x222);
    csr_clear(0x309, 0x200ul);
    check("mvip excludes external line", csr_read(0x309), 0x22);
    check("mip includes external line", csr_read(mip) & 0x200, 0x200);
    csr_set(0x30a, 1ul << 63);
    check("mvip STCE masks STIP", csr_read(0x309), 2);
    csr_write(0x309, 0ul);
    csr_clear(0x30a, 1ul << 63);
    check("mvip STCE write preserves dormant STIP", csr_read(0x309), 0x20);
    csr_write(0x309, 0ul);
    unsigned long before = illegal_count;
    csr_write(0xfb0, 0ul);
    csr_write(0xdb0, 0ul);
    check("topi read-only", illegal_count - before, 2);
    before = illegal_count;
    (void) csr_read(0x352);
    (void) csr_read(0x356);
    (void) csr_read(0x152);
    (void) csr_read(0x156);
    (void) csr_read(0x359);
    (void) csr_read(0x159);
    check("unimplemented aliases", illegal_count - before, 6);
    imsic_select(0, IMSIC_EIDELIVERY);
    imsic_select(1, IMSIC_EIDELIVERY);
    before = illegal_count;
    at_priv(lower_csrs, 0x800);
    check("S privilege", illegal_count - before, 6);
    before = illegal_count;
    at_priv(lower_csrs, 0);
    check("U privilege", illegal_count - before, 10);
    check("no unexpected traps", unexpected_count, 0);
    uart_printf("IMSIC CSR checks: %u passed, %u failed\n", checks - failures, failures);
    uart_puts(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
