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
 * Deterministic repro for the boot-hang root cause: cached store->load
 * visibility across the trap path. On rv64 the pointers round-trip through
 * sd/ld, matching the REG_S/REG_L width of the real rv64 handle_exception. A
 * 32-bit sw/lw round-trip of a bit-31 pointer would instead sign-extend and
 * PMA-fault, since Phase 3 M2 retired out-of-map aliasing.
 *
 * The handler increments cached g_ctr and main waits for it to reach TARGET.
 * The bug hides the store from later loads and stalls progress. An mtime
 * watchdog reports the stuck value instead of hanging forever.
 *
 * Run at hardware-realistic latency: DDR_MODEL_LATENCY>=70, CACHED_HAS_L2=0.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)

#define TARGET 200u
#define DDR_STACK_SIZE 4096u

volatile uint32_t g_ctr;        /* cached counter, written by handler, read by main */
volatile uint64_t g_percpu[16]; /* DDR per-cpu-like scratch (tp base) */
static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

static inline uint64_t clint_rdmtime(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = CLINT_MTIME_HI;
        lo = CLINT_MTIME_LO;
        hi2 = CLINT_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

static void clint_arm(uint64_t cmp)
{
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

/* Match the rv64 handle_exception: swap tp/mscratch; store sp at 8(tp) and
 * 16(tp) (REG_S = sd); reload sp from 8(tp) (REG_L = ld); then save GPRs to
 * that stack. A stale reload makes sp invalid and the saves re-trap. The
 * varying value prevents a false forward. */
__attribute__((naked, aligned(4))) static void ctr_entry(void)
{
    __asm__ volatile("csrrw tp, mscratch, tp\n" /* kernel: tp=0, mscratch=old tp(&g_percpu) */
                     "bnez  tp, 1f\n"
                     "csrr  tp, mscratch\n" /* tp = &g_percpu */
                     "sd    sp, 8(tp)\n"    /* *(tp+8) = sp */
                     "1:\n"
                     "sd    sp, 16(tp)\n"
                     "ld    sp, 8(tp)\n" /* sp = *(tp+8)  <-- cached store->load INTO sp */
                     "addi  sp, sp, -64\n"
                     "sd    ra, 0(sp)\n" /* GPR saves to the reloaded sp (fault if sp bad) */
                     "sd    t0, 8(sp)\n"
                     "sd    t1, 16(sp)\n"
                     "sd    t2, 24(sp)\n"
                     /* work: g_ctr++ */
                     "la    t1, g_ctr\n"
                     "lw    t2, 0(t1)\n"
                     "addi  t2, t2, 1\n"
                     "sw    t2, 0(t1)\n"
                     /* ack timer */
                     "li    t1, 0x40014004\n"
                     "li    t2, -1\n"
                     "sw    t2, 0(t1)\n"
                     "li    t1, 0x40014000\n"
                     "sw    t2, 0(t1)\n"
                     /* restore */
                     "ld    ra, 0(sp)\n"
                     "ld    t0, 8(sp)\n"
                     "ld    t1, 16(sp)\n"
                     "ld    t2, 24(sp)\n"
                     "addi  sp, sp, 64\n" /* sp back to trap-time value */
                     "csrw  mscratch, x0\n"
                     "mret\n");
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uart_printf("\n=== faithful handle_exception sw/lw-into-sp repro ===\n");
    g_ctr = 0u;
    for (int i = 0; i < 16; i++)
        g_percpu[i] = 0xB6B60000B6B60000ULL + (uint64_t) i;
    /* kernel convention: tp = per-cpu ptr, mscratch = 0 */
    __asm__ volatile("mv tp, %0" : : "r"((uintptr_t) &g_percpu[0]) : "memory");
    csr_write(mscratch, 0u);
    set_trap_handler(&ctr_entry);
    enable_timer_interrupt();

    uint64_t deadline = clint_rdmtime() + 1500000u;
    uint32_t observed = 0u;
    while (g_ctr < TARGET) {
        clint_arm(clint_rdmtime() + 200u);
        enable_interrupts();
        for (volatile int s = 0; s < 32; s++) {
        }
        disable_interrupts();
        observed = g_ctr;
        if (clint_rdmtime() > deadline) {
            break;
        }
    }

    if (g_ctr >= TARGET) {
        uart_printf("g_ctr=%u reached target -- store->load OK\n", g_ctr);
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf(
            "HANG: g_ctr stuck at %u (last observed %u) -- store->load broken\n", g_ctr, observed);
        uart_printf("<<FAIL>>\n");
    }
    for (;;) {
    }
}

int main(void)
{
    uintptr_t stack_top = ((uintptr_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~(uintptr_t) 0xFu;
    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
