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
 *   2. an actual machine timer interrupt set up entirely through the CLINT
 *      window fires with mcause = 0x8000_0007.
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

static volatile uint32_t g_cause;

/* Machine trap handler. GCC's "interrupt" attribute emits the register
 * save/restore and MRET, so it is safe as a normal C function. */
__attribute__((interrupt("machine"), aligned(4))) static void mtrap(void)
{
    uint32_t mc;
    __asm__ volatile("csrr %0, mcause" : "=r"(mc));
    g_cause = mc;
    /* Ack: push the compare (through the CLINT alias) to max so it cannot
     * refire. */
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = 0xFFFFFFFFu;
}

int main(void)
{
    int ok = 1;

    __asm__ volatile("csrw mtvec, %0" ::"r"(&mtrap)); /* direct mode */

    /* 1a. mtimecmp written via CLINT is visible at the native address. */
    CLINT_MTIMECMP_LO = 0x12345678u;
    CLINT_MTIMECMP_HI = 0x9ABCDEF0u;
    ok &= (NAT_MTIMECMP_LO == 0x12345678u);
    ok &= (NAT_MTIMECMP_HI == 0x9ABCDEF0u);

    /* 1b. msip written via CLINT is visible at the native address. */
    CLINT_MSIP = 1u;
    ok &= ((NAT_MSIP & 1u) == 1u);
    CLINT_MSIP = 0u;
    ok &= ((NAT_MSIP & 1u) == 0u);

    /* 1c. CLINT mtime and native mtime read the same advancing counter. */
    uint32_t t_clint = CLINT_MTIME_LO;
    uint32_t t_nat = NAT_MTIME_LO; /* read after -> >= */
    ok &= (t_nat >= t_clint);

    /* 2. A machine timer interrupt set up entirely through the CLINT window. */
    g_cause = 0u;
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu; /* block premature fire */
    CLINT_MTIMECMP_LO = CLINT_MTIME_LO + 1000u;
    CLINT_MTIMECMP_HI = 0u;
    __asm__ volatile("csrs mie, %0" ::"r"(0x80));    /* MTIE */
    __asm__ volatile("csrs mstatus, %0" ::"r"(0x8)); /* MIE */
    for (volatile int i = 0; i < 1000000 && g_cause == 0u; i++) {
    }
    ok &= (g_cause == 0x80000007u);

    puts_(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
