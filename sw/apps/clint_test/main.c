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
 * SiFive CLINT alias directed test (Increment 2 of the no-MMU Linux glue).
 *
 * FROST exposes a sifive,clint0-compatible window at 0x4001_0000 (msip @ +0,
 * mtimecmp @ +0x4000, mtime @ +0xBFF8) that aliases the native FROST timer
 * registers, so a stock Linux CLINT driver can deliver the timer tick. This
 * test proves the alias two ways:
 *   1. writes through the CLINT addresses are observable at the native timer
 *      addresses (same physical registers);
 *   2. a machine timer interrupt set up through the CLINT window alone
 *      fires with mcause = 0x8000_0000_0000_0007.
 */

#include <stdint.h>

/* SiFive CLINT alias window. */
#define CLINT_MSIP (*(volatile uint32_t *) 0x40010000u)
#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)

/* Native FROST timer registers (the aliased physical registers). */
#define NAT_MTIMECMP_LO (*(volatile uint32_t *) 0x40000018u)
#define NAT_MTIMECMP_HI (*(volatile uint32_t *) 0x4000001Cu)
#define NAT_MSIP (*(volatile uint32_t *) 0x40000020u)
#define NAT_MTIME_LO (*(volatile uint32_t *) 0x40000010u)

/* Native UART for the PASS/FAIL marker. */
#define UTX (*(volatile uint32_t *) 0x40000000u)
#define UTX_ST (*(volatile uint32_t *) 0x40000028u)
static void putc_(char c)
{
    while (!(UTX_ST & 1u)) {
    }
    UTX = (uint8_t) c;
}
static void puts_(const char *s)
{
    while (*s)
        putc_(*s++);
}

static volatile unsigned long g_cause;

/* Machine trap handler. GCC's "interrupt" attribute emits the register
 * save/restore and MRET, so it is safe as a normal C function. */
__attribute__((interrupt("machine"), aligned(4))) static void mtrap(void)
{
    unsigned long mc;
    __asm__ volatile("csrr %0, mcause" : "=r"(mc));
    g_cause = mc;
    /* Ack: push the compare (through the CLINT alias) to max so it cannot
     * refire. */
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = 0xFFFFFFFFu;
}

static void put_hex_(unsigned long v, int nibbles)
{
    static const char hex[] = "0123456789ABCDEF";
    for (int i = (nibbles - 1) * 4; i >= 0; i -= 4)
        putc_(hex[(v >> i) & 0xFu]);
}

int main(void)
{
    unsigned bad = 0; /* bit per failed check, for forensics */

    __asm__ volatile("csrw mtvec, %0" ::"r"(&mtrap)); /* direct mode */

    /* 1a. mtimecmp written via CLINT is visible at the native address. */
    CLINT_MTIMECMP_LO = 0x12345678u;
    CLINT_MTIMECMP_HI = 0x9ABCDEF0u;
    bad |= (NAT_MTIMECMP_LO == 0x12345678u) ? 0u : (1u << 0);
    bad |= (NAT_MTIMECMP_HI == 0x9ABCDEF0u) ? 0u : (1u << 1);

    /* 1b. msip written via CLINT is visible at the native address. */
    CLINT_MSIP = 1u;
    bad |= ((NAT_MSIP & 1u) == 1u) ? 0u : (1u << 2);
    CLINT_MSIP = 0u;
    bad |= ((NAT_MSIP & 1u) == 0u) ? 0u : (1u << 3);

    /* 1c. CLINT mtime and native mtime read the same advancing counter. */
    uint32_t t_clint = CLINT_MTIME_LO;
    uint32_t t_nat = NAT_MTIME_LO; /* read after -> >= */
    bad |= (t_nat >= t_clint) ? 0u : (1u << 4);

    /* 2. A machine timer interrupt set up entirely through the CLINT window. */
    g_cause = 0u;
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu; /* block premature fire */
    CLINT_MTIMECMP_LO = CLINT_MTIME_LO + 1000u;
    CLINT_MTIMECMP_HI = 0u;
    __asm__ volatile("csrs mie, %0" ::"r"(0x80));    /* MTIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(0x8)); /* MIE */
    for (volatile int i = 0; i < 1000000 && g_cause == 0u; i++) {
    }
    bad |= (g_cause == ((1ul << 63) | 7u)) ? 0u : (1u << 5); /* MTI at XLEN-1 */

    if (bad == 0u) {
        puts_("\r\n<<PASS>>\r\n");
    } else {
        puts_("\r\nbad=0x");
        put_hex_(bad, 2);
        puts_(" cause=0x");
        put_hex_(g_cause, 16);
        puts_("\r\n<<FAIL>>\r\n");
    }
    for (;;) {
    }
    return 0;
}
