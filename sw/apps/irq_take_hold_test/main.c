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
 * Interrupt takes around precise stores at the ROB head.
 *
 * Device store loops: a machine timer interrupt arrives while a loop of
 * device stores (sw; j, sw; nop; j, sw; sw; j) runs. Each store holds the
 * device shield until it retires, and the next store reaches the head as the
 * previous one retires. The take must come within 500 cycles; the handler
 * returns to a stub that ends the loop.
 *
 * LR/SC: the timer handler re-arms mtimecmp a short, varying time ahead, so
 * interrupts arrive at every point of an LR/SC increment loop, including
 * while an LR or an SC waits at the ROB head. The counter lives in .data:
 * uncached BRAM in the bram configuration, where the SC writes through the
 * precise uncached store path, and cached DDR in the ddr configuration.
 * Every increment must land exactly once and interrupts must be taken.
 */

#include <stdint.h>

#include "trap.h"

#define ITERS 3000u
#define REARM 300u

volatile uint32_t g_taken;
volatile uint64_t g_count;

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_dec(unsigned long v)
{
    char b[24];
    int i = 0;
    do {
        b[i++] = (char) ('0' + v % 10);
        v /= 10;
    } while (v);
    while (i)
        uart_putc(b[--i]);
}

/* Count the take and move mtimecmp REARM ticks ahead. */
__attribute__((naked, aligned(4))) static void timer_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     "la   t0, g_taken\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x4000001C\n" /* MTIMECMP_HI */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "lw   t2, 4(t0)\n" /* MTIME_HI */
                     "la   t0, g_taken\n"
                     "lw   t0, 0(t0)\n"
                     "andi t0, t0, 15\n" /* vary the arrival phase */
                     "add  t1, t1, t0\n"
                     "addi t1, t1, %0\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO */
                     "sw   t1, 0(t0)\n"
                     "sw   t2, 4(t0)\n" /* MTIMECMP_HI */
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n" ::"i"(REARM));
}

/* Phase 2: a device store loop that never exits on its own. The handler
 * records the take latency and returns to st_exit. */
volatile uint64_t g_lat[3];
volatile uint32_t g_trial;
__attribute__((naked, aligned(64))) static void st_loop_j(void)
{
    __asm__ volatile("1: sw zero, 0(a0)\n j 1b\n");
}
__attribute__((naked, aligned(64))) static void st_loop_jj(void)
{
    __asm__ volatile("1: sw zero, 0(a0)\n nop\n j 1b\n");
}
__attribute__((naked, aligned(64))) static void st_loop_ss(void)
{
    __asm__ volatile("1: sw zero, 0(a0)\n sw zero, 0(a0)\n j 1b\n");
}
__attribute__((naked, used, aligned(4))) void st_exit(void)
{
    __asm__ volatile("ret\n");
}
__attribute__((naked, aligned(4))) static void loop_handler(void)
{
    __asm__ volatile("li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "lw   t2, 8(t0)\n" /* MTIMECMP_LO */
                     "sub  t1, t1, t2\n"
                     "la   t0, g_trial\n"
                     "lw   t2, 0(t0)\n"
                     "slli t2, t2, 3\n"
                     "la   t0, g_lat\n"
                     "add  t0, t0, t2\n"
                     "sd   t1, 0(t0)\n"
                     "li   t0, 0x4000001C\n" /* MTIMECMP_HI */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n"
                     "la   t0, st_exit\n"
                     "csrw mepc, t0\n"
                     "mret\n");
}

static void run_store_loop(uint32_t trial, void (*fn)(void))
{
    g_trial = trial;
    g_lat[trial] = ~0ull;
    set_trap_handler(&loop_handler);
    MTIMECMP_HI = 0xFFFFFFFFu;
    uint32_t now = MTIME_LO;
    MTIMECMP_LO = now + 2000u;
    MTIMECMP_HI = MTIME_HI;
    enable_timer_interrupt();
    enable_interrupts();
    register unsigned long a0 __asm__("a0") = 0x40000020ul; /* MSIP */
    __asm__ volatile("jalr ra, 0(%1)\n" : "+r"(a0) : "r"(fn) : "ra", "t0", "t1", "t2", "memory");
    disable_interrupts();
    disable_timer_interrupt();
}

int main(void)
{
    uart_puts("\r\n=== interrupt takes around precise stores ===\r\n");
    run_store_loop(0, st_loop_j);
    run_store_loop(1, st_loop_jj);
    run_store_loop(2, st_loop_ss);
    int lat_ok = 1;
    for (uint32_t t = 0; t < 3; t++) {
        uart_puts("store loop ");
        uart_dec(t);
        uart_puts(" latency=");
        uart_dec((unsigned long) g_lat[t]);
        uart_puts("\r\n");
        if (g_lat[t] > 500u)
            lat_ok = 0;
    }
    set_trap_handler(&timer_handler);
    g_taken = 0;
    g_count = 0;
    MTIMECMP_HI = 0;
    MTIMECMP_LO = 0;
    enable_timer_interrupt();
    enable_interrupts();

    for (uint32_t i = 0; i < ITERS; i++) {
        uint64_t old, fail;
        __asm__ volatile("1: lr.d %0, (%2)\n"
                         "   addi %0, %0, 1\n"
                         "   sc.d %1, %0, (%2)\n"
                         "   bnez %1, 1b\n"
                         : "=&r"(old), "=&r"(fail)
                         : "r"(&g_count)
                         : "memory");
    }

    disable_interrupts();
    disable_timer_interrupt();
    uart_puts("count=");
    uart_dec((unsigned long) g_count);
    uart_puts(" taken=");
    uart_dec(g_taken);
    uart_puts("\r\n");
    if (g_count == ITERS && g_taken >= 10u && lat_ok)
        uart_puts("<<PASS>>\r\n");
    else
        uart_puts("[FAIL] slow take, lost increment or no interrupts\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
