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

/* Direct-delivery register, delegation, access-size and interrupt tests.
 * Source 1 is the ns16550 THRE level. Detached sources test claim side
 * effects independently of the UART's transmit state. */

#include <stdint.h>

#include "aplic.h"
#include "trap.h"

/* ---- UART ---- */
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

#define REG32(a) (*(volatile uint32_t *) (a))
#define REG16(a) (*(volatile uint16_t *) (a))
#define REG8(a) (*(volatile uint8_t *) (a))
#define REG64(a) (*(volatile uint64_t *) (a))
#define NS16550_IER REG32(0x40001004ul)
#define MIP_SEIP (1ul << 9)

static int report(const char *name, unsigned long got, unsigned long want)
{
    uart_puts(got == want ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return got == want;
}

/* The ns16550 THRE level is ns_ier[1] && i_uart_tx_ready, high while the
 * transmit FIFO is not almost full. UART_TX_STATUS bit 0 reads the same
 * signal, so wait for it before expecting a raise. */
static void wait_tx_idle(void)
{
    for (int i = 0; i < 400000; i++) {
        if (REG32(0x40000028UL) & 1)
            return;
    }
}

/* Allow for registered propagation from the APLIC source to mip. */
static unsigned long poll_mip(unsigned long mask, unsigned long want)
{
    for (int i = 0; i < 20000; i++) {
        if ((csr_read(mip) & mask) == want)
            return want;
    }
    return csr_read(mip) & mask;
}

static void reset_aplic(void)
{
    NS16550_IER = 0;
    for (unsigned long base = APLIC_M_BASE; base <= APLIC_S_BASE; base += 0x8000) {
        APLIC_DOMAINCFG(base) = 0;
        APLIC_IDELIVERY(base) = 0;
        APLIC_IFORCE(base) = 0;
        APLIC_ITHRESHOLD(base) = 0;
    }
    for (unsigned int source = 1; source <= APLIC_NUM_SOURCES; source++)
        APLIC_SOURCECFG(APLIC_M_BASE, source) = 0;
}

/* Check both 32-bit lanes and both domains. A doubleword load is aligned
 * at topi, so its upper half covers claimi without an alignment exception. */
static int access_sizes(unsigned long base)
{
    int ok = 1;
    APLIC_SOURCECFG(base, 2) = APLIC_SOURCE_DETACHED;
    APLIC_SOURCECFG(base, 3) = APLIC_SOURCE_DETACHED;
    APLIC_TARGET(base, 2) = 2;
    APLIC_TARGET(base, 3) = 3;
    REG8(base + 0x3008) = 7;
    REG8(base + 0x300C) = 7;
    ok &= report("size byte-write-low", APLIC_TARGET(base, 2), 2);
    ok &= report("size byte-write-high", APLIC_TARGET(base, 3), 3);
    REG16(base + 0x3008) = 7;
    REG16(base + 0x300C) = 7;
    ok &= report("size half-write-low", APLIC_TARGET(base, 2), 2);
    ok &= report("size half-write-high", APLIC_TARGET(base, 3), 3);
    REG64(base + 0x3008) = 0x0000000700000007ul;
    ok &= report("size double-write-low", APLIC_TARGET(base, 2), 2);
    ok &= report("size double-write-high", APLIC_TARGET(base, 3), 3);
    ok &= report("size byte-read-low", REG8(base + 0x3008), 0);
    ok &= report("size byte-read-high", REG8(base + 0x300C), 0);
    ok &= report("size half-read-low", REG16(base + 0x3008), 0);
    ok &= report("size half-read-high", REG16(base + 0x300C), 0);
    ok &= report("size double-read", REG64(base + 0x3008), 0);

    APLIC_SETIENUM(base) = 2;
    APLIC_SETIPNUM(base) = 2;
    ok &= report("size byte-claim-zero", REG8(base + 0x401C), 0);
    ok &= report("size byte-claim-pending", APLIC_SETIP(base), 1u << 2);
    ok &= report("size half-claim-zero", REG16(base + 0x401C), 0);
    ok &= report("size half-claim-pending", APLIC_SETIP(base), 1u << 2);
    ok &= report("size double-claim-zero", REG64(base + 0x4018), 0);
    ok &= report("size double-claim-pending", APLIC_SETIP(base), 1u << 2);
    ok &= report("size topi", APLIC_TOPI(base), 0x00020002);
    ok &= report("size topi-no-claim", APLIC_TOPI(base), 0x00020002);
    ok &= report("size word-claim", APLIC_CLAIMI(base), 0x00020002);
    ok &= report("size word-consumed", APLIC_CLAIMI(base), 0);
    APLIC_IFORCE(base) = 1;
    ok &= report("size byte-empty-claim", REG8(base + 0x401C), 0);
    ok &= report("size half-empty-claim", REG16(base + 0x401C), 0);
    ok &= report("size double-empty-claim", REG64(base + 0x4018), 0);
    ok &= report("size force-preserved", APLIC_IFORCE(base), 1);
    ok &= report("size word-empty-claim", APLIC_CLAIMI(base), 0);
    ok &= report("size force-cleared", APLIC_IFORCE(base), 0);
    return ok;
}

static volatile unsigned long g_irq_cause;
static volatile unsigned long g_irq_claim;

__attribute__((naked, aligned(4))) static void m_ext_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "csrr t0, mcause\n"
                     "la   t1, g_irq_cause\n"
                     "sd   t0, 0(t1)\n"
                     "li   t1, 0x4400401c\n"
                     "lw   t0, 0(t1)\n"
                     "la   t1, g_irq_claim\n"
                     "sd   t0, 0(t1)\n"
                     "li   t1, 0x40001004\n"
                     "sw   zero, 0(t1)\n" /* drop the source's level */
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n");
}

int main(void)
{
    int ok = 1;
    uart_puts("\r\n=== APLIC test ===\r\n");

    ok &= report("reset machine-domain", APLIC_DOMAINCFG(APLIC_M_BASE), 0x80000000);
    ok &= report("reset supervisor-domain", APLIC_DOMAINCFG(APLIC_S_BASE), 0x80000000);
    ok &= report("reset source", APLIC_SOURCECFG(APLIC_M_BASE, 1), 0);
    ok &= report("reset delivery", APLIC_IDELIVERY(APLIC_M_BASE), 0);
    APLIC_TARGET(APLIC_M_BASE, 2) = 3;
    ok &= report("inactive target-zero", APLIC_TARGET(APLIC_M_BASE, 2), 0);
    APLIC_SOURCECFG(APLIC_M_BASE, 2) = APLIC_SOURCE_DETACHED;
    ok &= report("inactive target-retained", APLIC_TARGET(APLIC_M_BASE, 2), 3);
    APLIC_TARGET(APLIC_M_BASE, 2) = 0;
    ok &= report("priority zero-warl", APLIC_TARGET(APLIC_M_BASE, 2), 1);
    APLIC_TARGET(APLIC_M_BASE, 2) = 0xFFFFFFFFu;
    ok &= report("target warl", APLIC_TARGET(APLIC_M_BASE, 2), 7);
    APLIC_ITHRESHOLD(APLIC_M_BASE) = 0xFFFFFFFFu;
    ok &= report("threshold warl", APLIC_ITHRESHOLD(APLIC_M_BASE), 7);
    reset_aplic();
    for (unsigned int source = 1; source <= APLIC_NUM_SOURCES; source++)
        APLIC_SOURCECFG(APLIC_M_BASE, source) = APLIC_SOURCE_DETACHED;
    APLIC_SETIE(APLIC_M_BASE) = 0xFFFFFFFFu;
    ok &= report("enable five-sources", APLIC_SETIE(APLIC_M_BASE), 0x3E);
    reset_aplic();

    aplic_enable_machine_source(1);
    NS16550_IER = 2;
    wait_tx_idle();
    ok &= report("level meip", poll_mip(MIP_MEIP, MIP_MEIP), MIP_MEIP);
    ok &= report("level pending", APLIC_SETIP(APLIC_M_BASE), 2);
    ok &= report("level claim", APLIC_CLAIMI(APLIC_M_BASE), 0x00010001);
    wait_tx_idle();
    ok &= report("level remains-pending", APLIC_SETIP(APLIC_M_BASE), 2);
    ok &= report("level claim-again", APLIC_CLAIMI(APLIC_M_BASE), 0x00010001);
    APLIC_ITHRESHOLD(APLIC_M_BASE) = 1;
    ok &= report("threshold masks-equal", poll_mip(MIP_MEIP, 0), 0);
    APLIC_ITHRESHOLD(APLIC_M_BASE) = 2;
    ok &= report("threshold delivers-below", poll_mip(MIP_MEIP, MIP_MEIP), MIP_MEIP);
    APLIC_IDELIVERY(APLIC_M_BASE) = 0;
    ok &= report("delivery disabled", poll_mip(MIP_MEIP, 0), 0);
    ok &= report("delivery topi-live", APLIC_TOPI(APLIC_M_BASE), 0x00010001);
    APLIC_IDELIVERY(APLIC_M_BASE) = 1;
    APLIC_DOMAINCFG(APLIC_M_BASE) = 0;
    ok &= report("domain disabled", poll_mip(MIP_MEIP, 0), 0);
    NS16550_IER = 0;
    ok &= report("level drops", APLIC_SETIP(APLIC_M_BASE), 0);
    reset_aplic();

    ok &= access_sizes(APLIC_M_BASE);
    reset_aplic();
    APLIC_SOURCECFG(APLIC_M_BASE, 2) = APLIC_SOURCE_DELEGATE;
    APLIC_SOURCECFG(APLIC_M_BASE, 3) = APLIC_SOURCE_DELEGATE;
    ok &= report("delegate root", APLIC_SOURCECFG(APLIC_M_BASE, 2), APLIC_SOURCE_DELEGATE);
    ok &= access_sizes(APLIC_S_BASE);
    APLIC_SETIPNUM(APLIC_S_BASE) = 2;
    APLIC_IDELIVERY(APLIC_S_BASE) = 1;
    APLIC_DOMAINCFG(APLIC_S_BASE) = APLIC_DOMAINCFG_IE;
    ok &= report("delegate seip", poll_mip(MIP_SEIP, MIP_SEIP), MIP_SEIP);
    ok &= report("delegate meip-quiet", csr_read(mip) & MIP_MEIP, 0);
    ok &= report("delegate root-hidden", APLIC_SETIP(APLIC_M_BASE), 0);
    ok &= report("delegate root-claim", APLIC_CLAIMI(APLIC_M_BASE), 0);
    APLIC_CLRIPNUM(APLIC_M_BASE) = 2;
    ok &= report("delegate root-clear-ignored", APLIC_SETIP(APLIC_S_BASE), 4);
    ok &= report("delegate supervisor-claim", APLIC_CLAIMI(APLIC_S_BASE), 0x00020002);
    ok &= report("delegate seip-drops", poll_mip(MIP_SEIP, 0), 0);
    APLIC_SOURCECFG(APLIC_S_BASE, 1) = APLIC_SOURCE_DETACHED;
    ok &= report("delegate supervisor-isolation", APLIC_SOURCECFG(APLIC_S_BASE, 1), 0);
    APLIC_IFORCE(APLIC_S_BASE) = 1;
    ok &= report("force seip", poll_mip(MIP_SEIP, MIP_SEIP), MIP_SEIP);
    ok &= report("force claim-zero", APLIC_CLAIMI(APLIC_S_BASE), 0);
    ok &= report("force seip-drops", poll_mip(MIP_SEIP, 0), 0);
    reset_aplic();

    set_trap_handler(&m_ext_handler);
    aplic_enable_machine_source(1);
    NS16550_IER = 2;
    wait_tx_idle();
    (void) poll_mip(MIP_MEIP, MIP_MEIP);
    enable_external_interrupt();
    enable_interrupts();
    for (int i = 0; i < 2000 && g_irq_claim == 0; i++)
        __asm__ volatile("nop");
    disable_interrupts();
    disable_external_interrupt();
    ok &= report("take cause", g_irq_cause, 0x8000000000000000ul | 11ul);
    ok &= report("take claim", g_irq_claim, 0x00010001);
    ok &= report("take meip-clear", poll_mip(MIP_MEIP, 0), 0);
    reset_aplic();

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
