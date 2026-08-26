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
 * PLIC directed test (Phase 3 M6, plan D11). Exercises the register file
 * (priority/enable/threshold WARL widths), the level gateway (claim /
 * complete / re-raise / spurious claim), threshold masking, priority-0
 * never-interrupts, both contexts' EIP lines through the mip.MEIP and
 * mip.SEIP readbacks, and a full M-mode external-interrupt take that
 * claims and completes inside the handler.
 *
 * The controllable level source is the ns16550's THRE interrupt (PLIC
 * source 1): with the transmitter idle, IER[1] raises a stable high
 * level; clearing IER[1] drops it. Source 2 (the board pin) is tied low
 * in simulation and register-tested only. Self-checks over UART
 * (<<PASS>> / <<FAIL>>).
 */

#include <stdint.h>

#include "trap.h"

/* ---- minimal UART (UART_TX is provided by mmio.h via trap.h) ---- */
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
#define PLIC_BASE 0x44000000UL
#define PLIC_PRIO(s) REG32(PLIC_BASE + 4ul * (s))
#define PLIC_PENDING REG32(PLIC_BASE + 0x1000ul)
#define PLIC_EN_M REG32(PLIC_BASE + 0x2000ul)
#define PLIC_EN_S REG32(PLIC_BASE + 0x2080ul)
#define PLIC_THR_M REG32(PLIC_BASE + 0x200000ul)
#define PLIC_CLAIM_M REG32(PLIC_BASE + 0x200004ul)
#define PLIC_THR_S REG32(PLIC_BASE + 0x201000ul)
#define PLIC_CLAIM_S REG32(PLIC_BASE + 0x201004ul)
#define NS16550_IER REG32(0x40001004UL)

#define MIP_MEIP (1ul << 11)
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

/* The ns16550 THRE level is ns_ier[1] && uart_tx_ready: it rises only
 * once the serializer drains this test's own prints. Wait for TX idle
 * (the same tx_ready the level uses) before expecting a raise. */
static void wait_tx_idle(void)
{
    for (int i = 0; i < 400000; i++) {
        if (REG32(0x40000028UL) & 1)
            return;
    }
}

/* Bounded mip poll: the PLIC EIP and meip registrations are a few flops
 * deep; 1000 iterations is a generous bound either way. */
static unsigned long poll_mip(unsigned long mask, unsigned long want)
{
    for (int i = 0; i < 20000; i++) { /* UART drain margin */
        if ((csr_read(mip) & mask) == want)
            return want;
    }
    return csr_read(mip) & mask;
}

/* ---- M external-interrupt handler (case I): records mcause, claims,
 * drops the level, completes, and mrets back to the interrupted loop. ---- */
static volatile unsigned long g_irq_cause;
static volatile unsigned long g_irq_claim;

__attribute__((naked, aligned(4))) static void m_ext_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_irq_cause\n"
                     "sd   t0, 0(t1)\n"
                     "li   t1, 0x44200004\n" /* claim (destructive read) */
                     "lw   t0, 0(t1)\n"
                     "la   t2, g_irq_claim\n"
                     "sd   t0, 0(t2)\n"
                     "li   t2, 0x40001004\n" /* IER = 0: drop the level */
                     "sw   zero, 0(t2)\n"
                     "sw   t0, 0(t1)\n" /* complete */
                     "mret\n");
}

int main(void)
{
    int ok = 1;

    uart_puts("\r\n=== PLIC test ===\r\n");

    /* A: register resets and WARL widths. */
    ok &= report("A prio1-reset", PLIC_PRIO(1), 0);
    PLIC_PRIO(1) = 0xFFFFFFFFu;
    ok &= report("A prio1-warl", PLIC_PRIO(1), 7); /* 3-bit priorities */
    PLIC_PRIO(2) = 3;
    ok &= report("A prio2-rw", PLIC_PRIO(2), 3);
    PLIC_EN_M = 0xFFFFFFFFu;
    ok &= report("A en-m-warl", PLIC_EN_M, 6); /* sources 1..2 = bits 1..2 */
    PLIC_EN_M = 0;
    PLIC_THR_M = 0xFFFFFFFFu;
    ok &= report("A thr-m-warl", PLIC_THR_M, 7);
    PLIC_THR_M = 0;
    ok &= report("A claim-idle", PLIC_CLAIM_M, 0);

    /* B: the gateway raises on the THRE level; pending readback. */
    PLIC_PRIO(1) = 1;
    NS16550_IER = 0x2; /* THRE enable: level high while TX is idle */
    PLIC_EN_M = 0x2;   /* enable source 1 (bit 1 = ID 1) in context M */
    wait_tx_idle();
    ok &= report("B meip-raises", poll_mip(MIP_MEIP, MIP_MEIP), MIP_MEIP);
    ok &= report("B pending", PLIC_PENDING & 0x2, 0x2);

    /* C: claim returns the ID and drops pending/EIP; spurious claim is 0. */
    ok &= report("C claim-id", PLIC_CLAIM_M, 1);
    ok &= report("C meip-drops", poll_mip(MIP_MEIP, 0), 0);
    ok &= report("C spurious", PLIC_CLAIM_M, 0);

    /* D: complete with the level still high re-raises (level gateway). */
    PLIC_CLAIM_M = 1;
    wait_tx_idle();
    ok &= report("D re-raise", poll_mip(MIP_MEIP, MIP_MEIP), MIP_MEIP);

    /* E: claim, drop the level, complete: no re-raise. */
    ok &= report("E claim-id", PLIC_CLAIM_M, 1);
    NS16550_IER = 0;
    PLIC_CLAIM_M = 1;
    ok &= report("E no-re-raise", poll_mip(MIP_MEIP, 0), 0);

    /* F: threshold masks (prio 1 <= thr 7); unmasking re-raises. */
    NS16550_IER = 0x2;
    wait_tx_idle();
    PLIC_THR_M = 7;
    ok &= report("F masked", poll_mip(MIP_MEIP, 0), 0);
    PLIC_THR_M = 0;
    ok &= report("F unmasked", poll_mip(MIP_MEIP, MIP_MEIP), MIP_MEIP);

    /* G: priority 0 never interrupts and is never claimable. */
    PLIC_PRIO(1) = 0;
    ok &= report("G prio0-drops", poll_mip(MIP_MEIP, 0), 0);
    ok &= report("G prio0-claim", PLIC_CLAIM_M, 0);
    PLIC_PRIO(1) = 1;

    /* H: the S context: enable in ctx S only; SEIP readback follows while
     * MEIP stays quiet; the S claim/complete round-trips. */
    PLIC_EN_M = 0;
    PLIC_EN_S = 0x2;
    wait_tx_idle();
    ok &= report("H seip-raises", poll_mip(MIP_SEIP, MIP_SEIP), MIP_SEIP);
    ok &= report("H meip-quiet", csr_read(mip) & MIP_MEIP, 0);
    ok &= report("H claim-s", PLIC_CLAIM_S, 1);
    NS16550_IER = 0;
    PLIC_CLAIM_S = 1;
    ok &= report("H seip-drops", poll_mip(MIP_SEIP, 0), 0);
    PLIC_EN_S = 0;

    /* I: full M-mode take: pending source + MEIE + MIE -> the handler
     * claims, drops the level, completes; mcause is machine-external. */
    g_irq_cause = 0;
    g_irq_claim = 0;
    set_trap_handler(&m_ext_handler);
    PLIC_EN_M = 0x2;
    NS16550_IER = 0x2;
    wait_tx_idle();
    (void) poll_mip(MIP_MEIP, MIP_MEIP);
    enable_external_interrupt();
    enable_interrupts();
    for (int i = 0; i < 2000 && g_irq_claim == 0; i++)
        __asm__ volatile("nop");
    disable_interrupts();
    disable_external_interrupt();
    ok &= report("I take-cause", g_irq_cause, 0x8000000000000000ul | 11ul);
    ok &= report("I take-claim", g_irq_claim, 1);
    ok &= report("I meip-clear", poll_mip(MIP_MEIP, 0), 0);
    PLIC_EN_M = 0;

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
