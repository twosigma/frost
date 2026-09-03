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
 * Phase-swept M-mode ret_from_exception restore-window stress.
 *
 * Models the Linux no-MMU exit sequence once protected by the retired
 * ret_from_exception image patch. Timer phase sweeps every cycle offset:
 *
 *   <MIE=1 region>                      ticks become eligible
 *   rw_irqoff:  csrci mstatus, 8        disable IRQs before exit
 *               [lr.d t0, (frame)]      every other iteration, force SC store
 *               ld   a2, 0(frame)       PT_EPC load
 *   rw_sc:      sc.d x0, a2, (frame)    reservation clear, draining to DDR
 *   rw_wincsr:  csrw mstatus, a0        image {MIE=0, MPIE=1, MPP=U|M}
 *   rw_winepc:  csrw mepc, a2
 *               ld   t1..t4, 8..32(frame)   register-restore DDR loads
 *   rw_mret:    mret                    -> U-pad (ecall back) or M-pad
 *   rw_winend:
 *
 * An L1D-alias store evicts the cached-DDR frame each iteration, forcing misses
 * and a slow committed-SC drain.
 *
 * On every tick, mstatus.MIE must be clear at entry and mepc must not lie inside
 * (rw_irqoff,rw_winend). After csrci, M-mode delivery is ineligible through
 * mret; a held tick must appear at the post-MRET pad. Illegal-instruction traps
 * fail immediately, and each iteration must reach one landing pad. Every eighth
 * iteration also runs `csrsi mstatus,8; wfi; csrci mstatus,8` with a due timer.
 *
 * PASS requires all iterations, no invariant violations, and ticks spanning
 * the window. FAIL prints forensics.
 */

#include <stdint.h>

#include "trap.h"

#ifndef N_ITER
#define N_ITER 800u
#endif

/* Rotate through 64 line-spaced DDR frames. Dirtying the +0x20000 alias in the
 * 128 KiB direct-mapped L1D forces a cold next access. The region remains
 * within the simulation model's 64 MiB backing. */
#define FRAME_BASE 0x82800000u
#define FRAME_ALIAS_XOR 0x20000u

/* Mirror rv64 ret_from_exception with 8-byte pt_regs slots, ld/sc.d, full-width
 * handler saves, and mcause bit 63. Counters and CLINT MMIO remain 32-bit. */
#define XL "ld  "  /* XLEN register load                       */
#define XS "sd  "  /* XLEN register store                      */
#define XLR "lr.d" /* kernel-width reservation pair           */
#define XSC "sc.d"
#define XO0 "0" /* n * XLEN-byte frame offsets                */
#define XO1 "8"
#define XO2 "16"
#define XO3 "24"
#define XO4 "32"
#define XFRAME "48"   /* handler stack frame (5 saves, padded)  */
#define XAMO_OFF "48" /* AMO cell: clear of frame[0..4]       */
#define XMCAUSE_MTI "0x8000000000000007"
typedef uint64_t rw_word_t;

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

volatile uint32_t g_iter;      /* progress marker for hang triage            */
volatile uint32_t g_irq;       /* machine-timer tick count                   */
volatile uint32_t g_irq_pad;   /* ticks delivered at a landing pad: the tick
                                * arose inside the MIE=0 window and was held
                                * until after the MRET, the window-crossing
                                * mechanism under test                       */
volatile uint32_t g_pad;       /* landing-pad executions                     */
volatile uint32_t g_fail;      /* invariant violations                       */
volatile uint32_t g_fail_mepc; /* first violation: offending mepc            */
volatile uint32_t g_fail_kind; /* 1=mepc-in-window 2=MIE-at-entry 3=illegal  */
volatile uint32_t g_fail_arg;  /* extra forensic word (mcause/mstatus)       */

/* Window boundary labels (defined in the gadget below). */
extern const char rw_irqoff[];
extern const char rw_winend[];

/*
 * M-mode trap handler. Timer ticks: check the two invariants, re-arm the
 * timer with a drifting period (712 + (g_irq & 0xFF)) so the phase sweeps,
 * and return to the interrupted context untouched. Ecall-from-U (the U-pad
 * handoff) and any failure bounce to the continuation stashed in mscratch
 * with MPP=M. Illegal instruction records forensics and bounces.
 */
__attribute__((naked, aligned(4))) static void rw_trap_handler(void)
{
    __asm__ volatile("addi sp, sp, -" XFRAME "\n" XS " t0, " XO0 "(sp)\n" XS " t1, " XO1 "(sp)\n" XS
                     " t2, " XO2 "(sp)\n" XS " t3, " XO3 "(sp)\n" XS " t4, " XO4 "(sp)\n"
                     "csrr t0, mcause\n"
                     "li   t1, " XMCAUSE_MTI "\n"
                     "beq  t0, t1, 1f\n" /* machine timer            */
                     "li   t1, 8\n"
                     "beq  t0, t1, 5f\n" /* ecall from U: pad handoff */
                     /* ---- unexpected synchronous trap (illegal instr = the signature) */
                     /* la (auipc-based under medany), here and below: absolute
                      * lui %hi cannot materialize the ddr build's 0x8xxx_xxxx
                      * data addresses at lp64. */
                     "la   t1, g_fail\n"
                     "lw   t2, 0(t1)\n"
                     "addi t2, t2, 1\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_fail_kind\n"
                     "li   t2, 3\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_fail_arg\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_fail_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "j    5f\n" /* bounce to continuation; C reports */
                     /* ---- machine timer ---- */
                     "1:\n"
                     /* Sweep-coverage counter: a delivery at a landing pad means the tick
                      * arose inside the MIE=0 window and was held until after the MRET. */
                     "csrr t1, mepc\n"
                     "la   t2, u_pad_start\n"
                     "bltu t1, t2, 7f\n"
                     "la   t2, pads_end\n"
                     "bgeu t1, t2, 7f\n"
                     "la   t3, g_irq_pad\n"
                     "lw   t4, 0(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, 0(t3)\n"
                     "7:\n"
                     /* Invariant 2: mepc must not be strictly inside (rw_irqoff, rw_winend) */
                     "la   t2, rw_irqoff\n"
                     "bleu t1, t2, 2f\n" /* <= csrci: legal (enabled region)  */
                     "la   t2, rw_winend\n"
                     "bgeu t1, t2, 2f\n" /* >= post-mret label: legal          */
                     "la   t3, g_fail\n"
                     "lw   t4, 0(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, 0(t3)\n"
                     "la   t3, g_fail_kind\n"
                     "li   t4, 1\n"
                     "sw   t4, 0(t3)\n"
                     "la   t3, g_fail_mepc\n"
                     "sw   t1, 0(t3)\n"
                     "2:\n"
                     /* Invariant 1: mstatus.MIE must be 0 at handler entry */
                     "csrr t1, mstatus\n"
                     "andi t2, t1, 8\n"
                     "beqz t2, 3f\n"
                     "la   t3, g_fail\n"
                     "lw   t4, 0(t3)\n"
                     "addi t4, t4, 1\n"
                     "sw   t4, 0(t3)\n"
                     "la   t3, g_fail_kind\n"
                     "li   t4, 2\n"
                     "sw   t4, 0(t3)\n"
                     "la   t3, g_fail_arg\n"
                     "sw   t1, 0(t3)\n"
                     "3:\n"
                     /* re-arm: mtimecmp = mtime + 712 + (g_irq & 0xFF); g_irq++ */
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "andi t2, t1, 0xFF\n"
                     "addi t2, t2, 712\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO (HI pinned 0 in main) */
                     "sw   t1, 0(t0)\n" XL " t0, " XO0 "(sp)\n" XL " t1, " XO1 "(sp)\n" XL
                     " t2, " XO2 "(sp)\n" XL " t3, " XO3 "(sp)\n" XL " t4, " XO4 "(sp)\n"
                     "addi sp, sp, " XFRAME "\n"
                     "mret\n"
                     /* ---- bounce to the gadget continuation in M-mode ---- */
                     "5:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n" /* MPP = M */
                     XL " t0, " XO0 "(sp)\n" XL " t1, " XO1 "(sp)\n" XL " t2, " XO2 "(sp)\n" XL
                     " t3, " XO3 "(sp)\n" XL " t4, " XO4 "(sp)\n"
                     "addi sp, sp, " XFRAME "\n"
                     "mret\n");
}

/* Landing pads, in one naked function so [u_pad_start, pads_end) is a single
 * contiguous range the handler can classify mepc against.
 *   u_pad_start: U-mode pad. Bumps g_pad (FROST has no memory protection in
 *                M/U) and ecalls back to M; the handler bounces on.
 *   m_pad_start: M-mode pad. Bumps g_pad and jumps straight to the continuation.
 */
extern const char u_pad_start[];
extern const char m_pad_start[];
__attribute__((naked, aligned(4))) void pads(void)
{
    __asm__ volatile(".global u_pad_start\n"
                     "u_pad_start:\n"
                     "la   t0, g_pad\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "ecall\n"
                     ".global m_pad_start\n"
                     "m_pad_start:\n"
                     "la   t0, g_pad\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "csrr t0, mscratch\n"
                     "jr   t0\n"
                     ".global pads_end\n"
                     "pads_end:\n"
                     "nop\n");
}

/*
 * One restore-window iteration. a0 image = {MPIE=1, MPP per variant, MIE=0};
 * frame[0] holds the pad address ("PT_EPC"). arm_lr=1 issues an LR first so
 * the SC succeeds and its store drains; arm_lr=0 leaves the SC failing, like
 * the kernel's usual dangling-reservation-free case.
 */
__attribute__((noinline)) static void
run_window(uint32_t image, volatile rw_word_t *frame, uint32_t arm_lr, uint32_t do_amo)
{
    __asm__ volatile("la   t0, 9f\n"
                     "csrw mscratch, t0\n" /* continuation for pads/handler   */
                     /* handler-tail analog: interrupts enabled, a little work */
                     "csrsi mstatus, 8\n"
                     "addi t1, x0, 7\n"
                     "slli t1, t1, 3\n"
                     "xor  t1, t1, t0\n"
                     "andi t1, t1, 255\n"
                     /* variant: a cached-region AMO with interrupts enabled, so swept
                      * ticks land while the AMO owns the ROB head and exercise the AMO
                      * interrupt shield's take-deferral right before the window */
                     "beqz %3, 8f\n"
                     "addi t1, %1, " XAMO_OFF "\n"
                     "amoswap.w t2, t1, (t1)\n"
                     "8:\n"
                     ".global rw_irqoff\n"
                     "rw_irqoff:\n"
                     "csrci mstatus, 8\n"                /* kernel IRQ-off before exit       */
                     "beqz  %2, 6f\n" XLR "  t1, (%1)\n" /* variant: arm dangling reservation */
                     "6:\n" XL " a2, " XO0 "(%1)\n"      /* PT_EPC                        */
                     ".global rw_sc\n"
                     "rw_sc:\n" XSC " x0, a2, (%1)\n" /* reservation-clear store          */
                     ".global rw_wincsr\n"
                     "rw_wincsr:\n"
                     "csrw mstatus, %0\n" /* image {MIE=0, MPIE=1, MPP=U|M}    */
                     ".global rw_winepc\n"
                     "rw_winepc:\n"
                     "csrw mepc, a2\n" XL " t1, " XO1 "(%1)\n" /* register-restore DDR loads    */
                     XL " t2, " XO2 "(%1)\n" XL " t3, " XO3 "(%1)\n" XL " t4, " XO4 "(%1)\n"
                     ".global rw_mret\n"
                     "rw_mret:\n"
                     "mret\n"
                     ".global rw_winend\n"
                     "rw_winend:\n"
                     "9:\n"
                     :
                     : "r"(image), "r"(frame), "r"(arm_lr), "r"(do_amo)
                     : "t0", "t1", "t2", "t3", "t4", "a2", "memory");
}

int main(void)
{
    uart_puts("\r\n=== restore-window stress ===\r\n");
    set_trap_handler(&rw_trap_handler);

    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 200;
    enable_timer_interrupt(); /* mie.MTIE; global MIE toggled per iteration */

    for (uint32_t i = 0; i < N_ITER; i++) {
        g_iter = i;
        uint32_t pad_before = g_pad;

        /* Rotate the frame across 64 line-spaced slots. Write it, then dirty
         * its L1D alias (same set, 128 KiB direct-mapped) so the just-written
         * frame line is evicted: its write-back drains to DDR and the window's
         * PT_EPC load and SC miss cold. That refill in turn evicts the dirty
         * alias line, keeping a write-back draining inside the window. */
        volatile rw_word_t *frame = (volatile rw_word_t *) (FRAME_BASE + ((i & 63u) << 6));
        volatile rw_word_t *alias = (volatile rw_word_t *) ((uintptr_t) frame ^ FRAME_ALIAS_XOR);

        uint32_t to_umode = i & 1u;
        frame[0] =
            to_umode ? (rw_word_t) (uintptr_t) u_pad_start : (rw_word_t) (uintptr_t) m_pad_start;
        frame[1] = i;
        frame[2] = i ^ 0x55555555u;
        frame[3] = ~i;
        frame[4] = i * 3u;
        alias[0] = i;
        alias[4] = i ^ 0xA5A5A5A5u;

        /* Place the next tick at a finely swept offset around window entry
         * (the handler's own re-arm then keeps the phase drifting). */
        MTIMECMP_LO = (uint32_t) rdmtime() + 90u + ((i * 13u) & 0x1FFu);

        /* Every 8th iteration: kernel idle shape with a due timer. */
        if ((i & 7u) == 7u) {
            __asm__ volatile("csrsi mstatus, 8\n"
                             "wfi\n"
                             "csrci mstatus, 8\n" ::
                                 : "memory");
        }

        uint32_t image = 0x80u | (to_umode ? 0u : 0x1800u); /* MPIE | MPP */
        run_window(image, frame, (i >> 1) & 1u, (i & 3u) == 3u);

        if (g_pad != pad_before + 1u) {
            g_fail++;
            g_fail_kind = 4;
            g_fail_arg = g_pad - pad_before;
            break;
        }
        if (g_fail)
            break;
    }

    disable_timer_interrupt();
    uart_puts("iters=");
    uart_hex(g_iter);
    uart_puts(" irqs=");
    uart_hex(g_irq);
    uart_puts(" pad_irqs=");
    uart_hex(g_irq_pad);
    uart_puts(" pads=");
    uart_hex(g_pad);
    uart_puts("\r\n");
    /* The sweep must have exercised the mechanism: demand ticks overall and
     * held ticks delivered at the pads (window crossings). */
    if (g_fail == 0 && g_pad == N_ITER && g_irq >= (N_ITER / 4u) && g_irq_pad >= 8u) {
        uart_puts("<<PASS>>\r\n");
    } else {
        uart_puts("fail_kind=");
        uart_hex(g_fail_kind);
        uart_puts(" mepc=");
        uart_hex(g_fail_mepc);
        uart_puts(" arg=");
        uart_hex(g_fail_arg);
        uart_puts(" window=[");
        uart_hex((uint32_t) (uintptr_t) rw_irqoff);
        uart_puts(",");
        uart_hex((uint32_t) (uintptr_t) rw_winend);
        uart_puts("]\r\n<<FAIL>>\r\n");
    }
    for (;;) {
    }
    return 0;
}
