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
 * Machine-timer + MRET deadlock stress test.
 *
 * Reproduce target: the residual flaky hang seen booting no-MMU Linux on
 * hardware. It is memory-size- and board-state-independent, ~50% of boots, and
 * frequently hangs at the first periodic machine-timer interrupts (right after
 * the kernel switches to the CLINT clocksource). The U-mode interrupt-resume-PC
 * fix (cpu_ooo.sv) and the kernel MIE-clear patch made it flaky instead of
 * deterministic but did not close it -> a residual machine-timer trap-return
 * race in the FROST trap/MRET/flush machinery.
 *
 * This is the full linux_boot in miniature: an M-mode loop preempted by a
 * machine timer firing very frequently, the handler doing a real MRET back to
 * the loop, with the timer PHASE swept (period re-armed to mtime + 24..87 each
 * tick) so the timer lands at every cycle offset around the MRET / in the loop
 * across many thousands of ticks. If a timer landing at a bad cycle deadlocks
 * the pipeline, the loop counter stops advancing and `<<PASS>>` is never
 * printed -> the cocotb harness times out (reproduced). If it survives all
 * phases for the whole run, it prints `<<PASS>>`.
 */

#include <stdint.h>

#include "trap.h"

static void uart_putc(char c) { UART_TX = (uint8_t) c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

volatile uint32_t g_irq;   /* timer-interrupt count (also drives the phase sweep) */
volatile uint32_t g_loop;  /* loop progress marker */
static volatile uint32_t buf[64];

/*
 * Naked M-mode timer handler: re-arm the timer to fire again in 24..87 cycles
 * (period = 24 + (g_irq & 0x3f), so the phase relative to the loop/MRET drifts
 * every tick and sweeps the whole window), bump g_irq, and MRET back to the
 * interrupted loop. Trap entry cleared MIE; the MRET restores it from MPIE, so
 * the next timer fires back in the loop -- exactly the kernel's pattern with
 * the MIE-clear patch applied. Saves only the regs it uses; everything else is
 * preserved by not touching it.
 */
__attribute__((naked, aligned(4))) static void mtimer_handler(void)
{
    __asm__ volatile(
        "addi sp, sp, -16\n"
        "sw   t0, 0(sp)\n"
        "sw   t1, 4(sp)\n"
        "sw   t2, 8(sp)\n"
        "lui  t0, %hi(g_irq)\n"
        "lw   t1, %lo(g_irq)(t0)\n"
        "andi t2, t1, 0x3f\n"
        "addi t2, t2, 24\n"          /* period = 24 + (g_irq & 0x3f) */
        "addi t1, t1, 1\n"
        "sw   t1, %lo(g_irq)(t0)\n"  /* g_irq++ */
        "li   t0, 0x40000010\n"      /* MTIME_LO */
        "lw   t1, 0(t0)\n"
        "add  t1, t1, t2\n"
        "li   t0, 0x40000018\n"      /* MTIMECMP_LO (HI stays 0, set in main) */
        "sw   t1, 0(t0)\n"
        "lw   t0, 0(sp)\n"
        "lw   t1, 4(sp)\n"
        "lw   t2, 8(sp)\n"
        "addi sp, sp, 16\n"
        "mret\n");
}

int main(void)
{
    uart_puts("\r\n=== mtimer MRET deadlock stress ===\r\n");
    set_trap_handler(&mtimer_handler);
    for (int i = 0; i < 64; i++)
        buf[i] = (uint32_t) i;

    /* Arm a frequent machine timer; handler re-arms each tick (phase sweep). */
    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 40;
    enable_timer_interrupt(); /* mie.MTIE */
    enable_interrupts();      /* mstatus.MIE */

    /* Loop with loads/stores/ALU so the timer preempts varied pipeline state
     * (in-flight memory ops, branches) at every swept phase. */
    uint32_t acc = 0;
    for (uint32_t i = 0; i < 20000u; i++) {
        g_loop = i;
        uint32_t k = i & 63u;
        acc += buf[k];
        acc ^= (acc << 1) | (acc >> 3);
        buf[k] = acc + i;
    }

    disable_timer_interrupt();
    uart_puts("survived: loop=");
    uart_hex(g_loop);
    uart_puts(" irqs=");
    uart_hex(g_irq);
    uart_puts(" acc=");
    uart_hex(acc);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
