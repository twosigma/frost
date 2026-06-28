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
 * visibility across the trap path.
 *
 * The handler increments a CACHED counter g_ctr every trap; the main loop spins
 * until it observes g_ctr reach a target. If a store of g_ctr is not visible to
 * a later load of g_ctr (the store->load bug), g_ctr never advances from the
 * observer's view and the loop hangs -- the exact livelock signature of the
 * real boot hang. A wall-clock (mtime) watchdog prints the stuck g_ctr instead
 * of hanging forever, so the failure is observable.
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
volatile uint32_t g_percpu[16]; /* DDR per-cpu-like scratch (tp base) */
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

/* Trap handler, faithful to a real kernel handler: saves/restores the GPRs it
 * uses on the (cached DDR) stack -- which IS the handle_exception store->load
 * pattern -- and explicitly checks a store->load with a VARYING value so a
 * forward-miss is always caught. 'X' on the raw UART if the reload is wrong. */
/* FULLY FAITHFUL to handle_exception's kernel-trap entry: the tp/mscratch swap,
 * then sw sp,8(tp); sw sp,12(tp); lw sp,8(tp) -- loading the trap-time sp back
 * INTO sp via the cached scratch slot -- then GPR saves to that reloaded sp.
 * If the cached store->load (lw sp,8(tp)) drops the just-stored sp, sp becomes
 * garbage and the GPR saves fault -> re-trap -> hang, exactly like the kernel. */
__attribute__((naked, aligned(4))) static void ctr_entry(void)
{
    __asm__ volatile("csrrw tp, mscratch, tp\n" /* kernel: tp=0, mscratch=old tp(&g_percpu) */
                     "bnez  tp, 1f\n"
                     "csrr  tp, mscratch\n" /* tp = &g_percpu */
                     "sw    sp, 8(tp)\n"    /* *(tp+8) = sp */
                     "1:\n"
                     "sw    sp, 12(tp)\n"
                     "lw    sp, 8(tp)\n" /* sp = *(tp+8)  <-- cached store->load INTO sp */
                     "addi  sp, sp, -64\n"
                     "sw    ra, 0(sp)\n" /* GPR saves to the reloaded sp (fault if sp bad) */
                     "sw    t0, 4(sp)\n"
                     "sw    t1, 8(sp)\n"
                     "sw    t2, 12(sp)\n"
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
                     "lw    ra, 0(sp)\n"
                     "lw    t0, 4(sp)\n"
                     "lw    t1, 8(sp)\n"
                     "lw    t2, 12(sp)\n"
                     "addi  sp, sp, 64\n" /* sp back to trap-time value */
                     "csrw  mscratch, x0\n"
                     "mret\n");
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uart_printf("\n=== faithful handle_exception sw/lw-into-sp repro ===\n");
    g_ctr = 0u;
    for (int i = 0; i < 16; i++)
        g_percpu[i] = 0xB6B60000u + (uint32_t) i;
    /* kernel convention: tp = per-cpu ptr, mscratch = 0 */
    __asm__ volatile("mv tp, %0" : : "r"((uint32_t) &g_percpu[0]) : "memory");
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
    uint32_t stack_top = ((uint32_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~0xFu;
    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
